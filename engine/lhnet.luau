--!strict
--[[
Written by Forest Hale 2003-06-15 and placed into public domain. (DarkPlaces lhnet.c / lhnet.h)
]]
--[[
	Port of lhnet.c @xonotic-v0.8.6 (the Linux build: IPv6 support, MSG_DONTWAIT, IP_TOS, IPV6_V6ONLY).
	Ported: LHNETADDRESS_FromPort, LHNETADDRESS_FromString (local:port, dotted-decimal IPv4 with sscanf's partial
	forms, the name cache), LHNETADDRESS_ToString, LHNETADDRESS_GetAddressType, LHNETADDRESS_GetInterfaceName,
	LHNETADDRESS_GetPort, LHNETADDRESS_SetPort, LHNETADDRESS_Compare, LHNET_Init, LHNET_DefaultDSCP,
	LHNET_Shutdown, LHNET_SleepUntilPacket_Microseconds (no-op), LHNET_OpenSocket_Connectionless,
	LHNET_CloseSocket, LHNET_AddressFromSocket, LHNET_Read, LHNET_Write. The LOOPBACK transport (the
	lhnet_packet_t list with its 10 second time(NULL) timeout and cl_netlocalping delay) is the C code.

	Representations:
	  lhnetaddress_t: a table { addresstype, port, family (sin_family / sin6_family: AF_INET 2, AF_INET6 10),
	    sinport (sin_port / sin6_port: the host-order value of htons((unsigned short)port)), addr (sin_addr: 4 byte
	    string, sin6_addr: 16 byte string), scope_id (sin6_scope_id) }; LHNETADDRESS_New() is the zeroed struct,
	    LHNETADDRESS_Copy(dst, src) is `*dst = *src`. (The C union lets in.sin_addr overlap in6.sin6_flowinfo;
	    nothing on the ported paths reads one through the other.)
	  lhnetsocket_t: { address, inetsocket (the backend handle), next, prev } in the C doubly linked list.
	  Packet contents are buffers with an explicit length (C: void * + int).

	Sockets that are not LOOP (INET4 / INET6, i.e. UDP) go through lhnet.backend, the interface the Roblox
	transport (platform/net, RemoteEvents) implements:
	  backend.open(address): (handle?, err: string?)  socket()+bind()+getsockname(): may rewrite address (the
	      bound port); nil = failure (err is printed like LHNETPRIVATE_StrError's text)
	  backend.close(handle)                            closesocket()
	  backend.read(handle, content: buffer, maxlength: number, address): number
	      recvfrom(): > 0 = bytes written to content[0..n-1] and address filled (addresstype, port, family,
	      sinport, addr); 0 = nothing waiting (EWOULDBLOCK); < 0 = error
	  backend.write(handle, content: buffer, length: number, address): number   sendto(): bytes sent, -1 error
	With lhnet.backend == nil the socket opens with no transport behind it (reads return 0, writes return the
	length as an unanswered UDP send would): `NOT YET PORTED: lhnet backend` is logged once.
	NOT YET PORTED: LHNETADDRESS_Resolve (getaddrinfo: DNS names and IPv6 text forms; logged once, resolution
	fails as with no network), the select() wait of LHNET_SleepUntilPacket_Microseconds.
]]
local prvm_edict = require("./prvm_edict")
local console = require("./console")
local libc = require("./_port/libc")

local lhnet = {}

local warned: { [string]: boolean } = {}
local function notPorted(what: string)
	if not warned[what] then
		warned[what] = true
		print("NOT YET PORTED: " .. what)
	end
end

-- lhnetaddresstype_t (lhnet.h L7-14)
lhnet.LHNETADDRESSTYPE_NONE = 0
lhnet.LHNETADDRESSTYPE_LOOP = 1
lhnet.LHNETADDRESSTYPE_INET4 = 2
lhnet.LHNETADDRESSTYPE_INET6 = 3
local LHNETADDRESSTYPE_NONE, LHNETADDRESSTYPE_LOOP = 0, 1
local LHNETADDRESSTYPE_INET4, LHNETADDRESSTYPE_INET6 = 2, 3
local AF_UNSPEC, AF_INET, AF_INET6 = 0, 2, 10 -- Linux <sys/socket.h>

export type Address = {
	addresstype: number,
	port: number,
	family: number,
	sinport: number,
	addr: string,
	scope_id: number,
}

export type Socket = {
	address: Address,
	inetsocket: any,
	next: any,
	prev: any,
}

-- a zeroed lhnetaddress_t
function lhnet.LHNETADDRESS_New(): Address
	return { addresstype = LHNETADDRESSTYPE_NONE, port = 0, family = 0, sinport = 0, addr = "", scope_id = 0 }
end
local New = lhnet.LHNETADDRESS_New

-- *dst = *src
function lhnet.LHNETADDRESS_Copy(dst: Address, src: Address)
	dst.addresstype = src.addresstype
	dst.port = src.port
	dst.family = src.family
	dst.sinport = src.sinport
	dst.addr = src.addr
	dst.scope_id = src.scope_id
end
local Copy = lhnet.LHNETADDRESS_Copy

local function memset0(a: Address)
	a.addresstype, a.port, a.family, a.sinport, a.addr, a.scope_id = 0, 0, 0, 0, "", 0
end

-- htons((unsigned short)port), kept as the host-order value of the 16-bit field
local function htons(port: number): number
	return port % 65536
end

-- the 4 / 16 bytes of the address field (zeroed memory past what was written)
local function inaddr(a: Address, n: number): string
	local s = a.addr
	if #s < n then
		return s .. string.rep("\0", n - #s)
	end
	return string.sub(s, 1, n)
end

-- to make LHNETADDRESS_FromString resolve repeated hostnames faster, cache them
local MAX_NAMECACHE = 64
type NameCache = { address: Address, expirationtime: number, name: string }
local namecache: { NameCache } = table.create(MAX_NAMECACHE) -- C element i at [i + 1]
for i = 1, MAX_NAMECACHE do
	namecache[i] = { address = New(), expirationtime = 0, name = "" }
end
local namecacheposition = 0

-- port: lhnet.c LHNETADDRESS_FromPort L122-157 @xonotic-v0.8.6
function lhnet.LHNETADDRESS_FromPort(address: Address?, addresstype: number, port: number): number
	if not address then
		return 0
	end
	if addresstype == LHNETADDRESSTYPE_LOOP then
		-- local:port  (loopback)
		memset0(address)
		address.addresstype = LHNETADDRESSTYPE_LOOP
		address.port = port
		return 1
	elseif addresstype == LHNETADDRESSTYPE_INET4 then
		-- 0.0.0.0:port  (INADDR_ANY, binds to all interfaces)
		memset0(address)
		address.addresstype = LHNETADDRESSTYPE_INET4
		address.port = port
		address.family = AF_INET
		address.sinport = htons(port)
		address.addr = "\0\0\0\0"
		return 1
	elseif addresstype == LHNETADDRESSTYPE_INET6 then
		-- [0:0:0:0:0:0:0:0]:port  (IN6ADDR_ANY, binds to all interfaces)
		memset0(address)
		address.addresstype = LHNETADDRESSTYPE_INET6
		address.port = port
		address.family = AF_INET6
		address.sinport = htons(port)
		address.addr = string.rep("\0", 16)
		return 1
	end
	return 0
end

-- port: lhnet.c LHNETADDRESS_Resolve L160-199 @xonotic-v0.8.6
local function LHNETADDRESS_Resolve(_address: Address, _name: string, _port: number): number
	-- getaddrinfo(name, port, AF_UNSPEC, SOCK_DGRAM): there is no resolver on Roblox
	notPorted("LHNETADDRESS_Resolve (getaddrinfo: DNS names / IPv6 text addresses; resolution fails)")
	return 0
end

-- sscanf(name, "%d.%d.%d.%d", &d1, &d2, &d3, &d4): the number of conversions and the values (glibc: %d skips
-- white space, takes an optional sign and decimal digits; the long result is stored into the int)
local function scan4(name: string): (number, { number })
	local d = { 0, 0, 0, 0 }
	local pos, n = 1, 0
	for k = 1, 4 do
		if k > 1 then
			if string.byte(name, pos) ~= 46 then -- '.'
				break
			end
			pos += 1
		end
		local ws = string.match(name, "^[ \t\n\v\f\r]*", pos) :: string
		pos += #ws
		local num = string.match(name, "^[+-]?%d+", pos)
		if not num then
			break
		end
		pos += #num
		local v = libc.strtol10(num)
		d[k] = v
		n += 1
	end
	return n, d
end

-- port: lhnet.c LHNETADDRESS_FromString L201-376 @xonotic-v0.8.6
function lhnet.LHNETADDRESS_FromString(address: Address?, str: string?, defaultport: number): number
	local i, port, resolved
	local namelen
	local name
	local addr_start: string
	local addr_end: number? = nil -- offset of the end in addr_start
	local port_name: string? = nil
	local addr_family = AF_UNSPEC

	if not address or not str or libc.cstr(str) == "" then
		return 0
	end
	local s = libc.cstr(str)
	memset0(address)
	address.addresstype = LHNETADDRESSTYPE_NONE
	port = 0

	-- If it's a bracketed IPv6 address
	if string.byte(s, 1) == 91 then -- '['
		local end_bracket = string.find(s, "]", 1, true)

		if end_bracket == nil then
			return 0
		end

		local after = string.byte(s, end_bracket + 1)
		if after == 58 then -- ':'
			port_name = string.sub(s, end_bracket + 2)
		elseif after ~= nil then
			return 0
		end

		addr_family = AF_INET6
		addr_start = string.sub(s, 2)
		addr_end = end_bracket - 2
	else
		addr_start = s

		-- If it's a numeric non-bracket IPv6 address (-> no port),
		-- or it's a numeric IPv4 address, or a name, with a port
		local first_colon = string.find(s, ":", 1, true)
		if first_colon ~= nil then
			local last_colon = string.find(s, ":", first_colon + 1, true)

			-- If it's an numeric IPv4 address, or a name, with a port
			if last_colon == nil then
				addr_end = first_colon - 1
				port_name = string.sub(s, first_colon + 1)
			else
				addr_family = AF_INET6
			end
		end
	end

	if addr_end ~= nil then
		namelen = addr_end
	else
		namelen = #addr_start
	end

	if namelen >= 128 then -- sizeof(name)
		namelen = 128 - 1
	end
	name = string.sub(addr_start, 1, namelen)

	if port_name then
		port = libc.atoi(port_name)
	end

	if port == 0 then
		port = defaultport
	end

	-- handle loopback
	if name == "local" then
		address.addresstype = LHNETADDRESSTYPE_LOOP
		address.port = port
		return 1
	end
	-- try to parse as dotted decimal ipv4 address first
	-- note this supports partial ip addresses
	local nconv, d = scan4(name)
	if
		addr_family ~= AF_INET6
		and nconv >= 1
		and d[1] % 4294967296 < 256
		and d[2] % 4294967296 < 256
		and d[3] % 4294967296 < 256
		and d[4] % 4294967296 < 256
	then
		-- parsed a valid ipv4 address
		address.addresstype = LHNETADDRESSTYPE_INET4
		address.port = port
		address.family = AF_INET
		address.sinport = htons(port)
		address.addr = string.char(d[1], d[2], d[3], d[4])
		return 1
	end
	i = 0
	while i < MAX_NAMECACHE do
		if namecache[i + 1].name == name then
			break
		end
		i += 1
	end
	if i < MAX_NAMECACHE and prvm_edict.realtime < namecache[i + 1].expirationtime then
		Copy(address, namecache[i + 1].address)
		address.port = port
		-- selene: allow(if_same_then_else)
		if address.addresstype == LHNETADDRESSTYPE_INET6 then
			address.sinport = htons(port)
			return 1
		elseif address.addresstype == LHNETADDRESSTYPE_INET4 then
			address.sinport = htons(port)
			return 1
		end
		return 0
	end

	local nc = namecache[namecacheposition + 1]
	nc.name = string.sub(name, 1, 64 - 1)
	nc.expirationtime = prvm_edict.realtime + 12 * 3600 -- 12 hours

	-- try resolving the address (handles dns and other ip formats)
	resolved = LHNETADDRESS_Resolve(address, name, port)
	if resolved ~= 0 then
		Copy(nc.address, address)
	else
		nc.address.addresstype = LHNETADDRESSTYPE_NONE
	end

	namecacheposition = (namecacheposition + 1) % MAX_NAMECACHE
	return resolved
end

-- port: lhnet.c LHNETADDRESS_ToString L537-608 @xonotic-v0.8.6
-- returns (C return value, the string written; "" when nothing was written)
function lhnet.LHNETADDRESS_ToString(
	address: Address?,
	stringbuffersize: number,
	includeport: boolean
): (number, string)
	if not address or stringbuffersize < 1 then
		return 0, ""
	end
	local t = address.addresstype
	if t == LHNETADDRESSTYPE_LOOP then
		if includeport then
			if stringbuffersize >= 12 then
				return 1, libc.snprintf(stringbuffersize, "local:%d", address.port)
			end
		else
			if stringbuffersize >= 6 then
				return 1, "local"
			end
		end
	elseif t == LHNETADDRESSTYPE_INET4 then
		local a = inaddr(address, 4)
		local a0, a1, a2, a3 = string.byte(a, 1, 4)
		if includeport then
			if stringbuffersize >= 22 then
				return 1, libc.snprintf(stringbuffersize, "%d.%d.%d.%d:%d", a0, a1, a2, a3, address.port)
			end
		else
			if stringbuffersize >= 16 then
				return 1, libc.snprintf(stringbuffersize, "%d.%d.%d.%d", a0, a1, a2, a3)
			end
		end
	elseif t == LHNETADDRESSTYPE_INET6 then
		local a = inaddr(address, 16)
		local w = table.create(8)
		for k = 0, 7 do
			w[k + 1] = string.format("%x", string.byte(a, 2 * k + 1) * 256 + string.byte(a, 2 * k + 2))
		end
		if includeport then
			if stringbuffersize >= 88 then
				return 1, libc.snprintf(stringbuffersize, "[%s]:%d", table.concat(w, ":"), address.port)
			end
		else
			if stringbuffersize >= 80 then
				return 1, libc.snprintf(stringbuffersize, "%s", table.concat(w, ":"))
			end
		end
	end
	return 0, ""
end

-- port: lhnet.c LHNETADDRESS_GetAddressType L610-616 @xonotic-v0.8.6
function lhnet.LHNETADDRESS_GetAddressType(address: Address?): number
	if address then
		return address.addresstype
	else
		return LHNETADDRESSTYPE_NONE
	end
end

-- port: lhnet.c LHNETADDRESS_GetInterfaceName L618-643 @xonotic-v0.8.6
function lhnet.LHNETADDRESS_GetInterfaceName(address: Address?, _ifnamelength: number): string?
	if address and address.addresstype == LHNETADDRESSTYPE_INET6 then
		-- if_indextoname(address->addr.in6.sin6_scope_id, ifname): no interfaces on Roblox
		notPorted("LHNETADDRESS_GetInterfaceName (if_indextoname)")
	end
	return nil
end

-- port: lhnet.c LHNETADDRESS_GetPort L645-650 @xonotic-v0.8.6
function lhnet.LHNETADDRESS_GetPort(address: Address?): number
	if not address then
		return -1
	end
	return address.port
end

-- port: lhnet.c LHNETADDRESS_SetPort L652-673 @xonotic-v0.8.6
function lhnet.LHNETADDRESS_SetPort(address: Address?, port: number): number
	if not address then
		return 0
	end
	address.port = port
	local t = address.addresstype
	-- selene: allow(if_same_then_else)
	if t == LHNETADDRESSTYPE_LOOP then
		return 1
	elseif t == LHNETADDRESSTYPE_INET4 then
		address.sinport = htons(port)
		return 1
	elseif t == LHNETADDRESSTYPE_INET6 then
		address.sinport = htons(port)
		return 1
	else
		return 0
	end
end

-- port: lhnet.c LHNETADDRESS_Compare L675-710 @xonotic-v0.8.6
function lhnet.LHNETADDRESS_Compare(address1: Address?, address2: Address?): number
	if not address1 or not address2 then
		return 1
	end
	if address1.addresstype ~= address2.addresstype then
		return 1
	end
	local t = address1.addresstype
	if t == LHNETADDRESSTYPE_LOOP then
		if address1.port ~= address2.port then
			return -1
		end
		return 0
	elseif t == LHNETADDRESSTYPE_INET4 then
		if address1.family ~= address2.family then
			return 1
		end
		if inaddr(address1, 4) ~= inaddr(address2, 4) then
			return 1
		end
		if address1.port ~= address2.port then
			return -1
		end
		return 0
	elseif t == LHNETADDRESSTYPE_INET6 then
		if address1.family ~= address2.family then
			return 1
		end
		if inaddr(address1, 16) ~= inaddr(address2, 16) then
			return 1
		end
		if address1.port ~= address2.port then
			return -1
		end
		return 0
	else
		return 1
	end
end

-- lhnetpacket_t (lhnet.c L712-724): data is a buffer of length bytes
export type Packet = {
	data: buffer,
	length: number,
	sourceport: number,
	destinationport: number,
	timeout: number,
	sentdoubletime: number,
	next: any,
	prev: any,
}

local lhnet_active = 0
-- the list heads (static lhnetsocket_t lhnet_socketlist / lhnetpacket_t lhnet_packetlist): sentinels whose
-- next / prev are nil until LHNET_Init, as in the zeroed C statics
local lhnet_socketlist: Socket = { address = New(), inetsocket = nil, next = nil, prev = nil }
local lhnet_packetlist: Packet =
	{ data = buffer.create(0), length = 0, sourceport = 0, destinationport = 0, timeout = 0, sentdoubletime = 0 }
local lhnet_default_dscp = 0
lhnet.lhnet_socketlist = lhnet_socketlist
lhnet.lhnet_packetlist = lhnet_packetlist -- (tests reorder / drop / duplicate loopback packets in it)

-- the transport for INET4 / INET6 sockets (see the header; nil = none yet)
lhnet.backend = nil :: any
-- time(NULL) (replaceable: tests pin the wall clock the loopback packet timeout uses)
lhnet.time = function(): number
	return os.time()
end
-- cl_netlocalping (netconn.c's cvar_t, set by NetConn_Init; nil = the unregistered static, value 0)
lhnet.cl_netlocalping = nil :: any

-- port: lhnet.c LHNET_Init L735-747 @xonotic-v0.8.6
function lhnet.LHNET_Init()
	if lhnet_active ~= 0 then
		return
	end
	lhnet_socketlist.next = lhnet_socketlist
	lhnet_socketlist.prev = lhnet_socketlist
	lhnet_packetlist.next = lhnet_packetlist
	lhnet_packetlist.prev = lhnet_packetlist
	lhnet_active = 1
end

-- port: lhnet.c LHNET_DefaultDSCP L749-759 @xonotic-v0.8.6
function lhnet.LHNET_DefaultDSCP(dscp: number): number
	local prev = lhnet_default_dscp
	if dscp >= 0 then
		lhnet_default_dscp = dscp
	end
	return prev
end

-- port: lhnet.c LHNET_Shutdown L761-783 @xonotic-v0.8.6
function lhnet.LHNET_Shutdown()
	local p
	if lhnet_active == 0 then
		return
	end
	while lhnet_socketlist.next ~= lhnet_socketlist do
		lhnet.LHNET_CloseSocket(lhnet_socketlist.next)
	end
	while lhnet_packetlist.next ~= lhnet_packetlist do
		p = lhnet_packetlist.next :: Packet
		p.prev.next = p.next
		p.next.prev = p.prev
	end
	lhnet_active = 0
end

-- port: lhnet.c LHNET_SleepUntilPacket_Microseconds L843-871 @xonotic-v0.8.6
function lhnet.LHNET_SleepUntilPacket_Microseconds(_microseconds: number)
	-- select() on the inet sockets with a timeout: the Roblox host loop waits between frames itself (see
	-- host.Host_Main_Frame); nothing to do here
end

local function backend_open(address: Address): (any, string?)
	local b = lhnet.backend
	if b == nil then
		notPorted("lhnet backend (INET4 / INET6 sockets have no transport: nothing is sent or received)")
		return true, nil
	end
	return b.open(address)
end

-- port: lhnet.c LHNET_OpenSocket_Connectionless L873-1057 @xonotic-v0.8.6
function lhnet.LHNET_OpenSocket_Connectionless(address: Address?): Socket?
	local s: Socket?
	if not address then
		return nil
	end
	local lhnetsocket: Socket = { address = New(), inetsocket = nil, next = nil, prev = nil }
	Copy(lhnetsocket.address, address)
	local t = lhnetsocket.address.addresstype
	if t == LHNETADDRESSTYPE_LOOP then
		if lhnetsocket.address.port == 0 then
			-- allocate a port dynamically
			-- this search will always terminate because there is never
			-- an allocated socket with port 0, so if the number wraps it
			-- will find the port is unused, and then refuse to use port
			-- 0, causing an intentional failure condition
			lhnetsocket.address.port = 1024
			while true do
				s = lhnet_socketlist.next
				while s ~= lhnet_socketlist do
					local ss = s :: Socket
					if
						ss.address.addresstype == lhnetsocket.address.addresstype
						and ss.address.port == lhnetsocket.address.port
					then
						break
					end
					s = ss.next
				end
				if s == lhnet_socketlist then
					break
				end
				-- (int wraparound)
				lhnetsocket.address.port = if lhnetsocket.address.port == 2147483647
					then -2147483648
					else lhnetsocket.address.port + 1
			end
		end
		-- check if the port is available
		s = lhnet_socketlist.next
		while s ~= lhnet_socketlist do
			local ss = s :: Socket
			if
				ss.address.addresstype == lhnetsocket.address.addresstype
				and ss.address.port == lhnetsocket.address.port
			then
				break
			end
			s = ss.next
		end
		if s == lhnet_socketlist and lhnetsocket.address.port ~= 0 then
			lhnetsocket.next = lhnet_socketlist
			lhnetsocket.prev = (lhnetsocket.next :: Socket).prev
			lhnetsocket.next.prev = lhnetsocket
			lhnetsocket.prev.next = lhnetsocket
			return lhnetsocket
		end
	elseif t == LHNETADDRESSTYPE_INET4 or t == LHNETADDRESSTYPE_INET6 then
		-- socket() + IPV6_V6ONLY + bind() + getsockname() + SO_BROADCAST + IP_TOS (lhnet_default_dscp << 2): the
		-- backend's open
		local handle, err = backend_open(lhnetsocket.address)
		if handle ~= nil then
			lhnetsocket.inetsocket = handle
			lhnetsocket.next = lhnet_socketlist
			lhnetsocket.prev = (lhnetsocket.next :: Socket).prev
			lhnetsocket.next.prev = lhnetsocket
			lhnetsocket.prev.next = lhnetsocket
			return lhnetsocket
		else
			console.Con_Printf("LHNET_OpenSocket_Connectionless: bind returned error: %s\n", err or "unknown error")
		end
	end
	return nil
end

-- port: lhnet.c LHNET_CloseSocket L1059-1078 @xonotic-v0.8.6
function lhnet.LHNET_CloseSocket(lhnetsocket: Socket?)
	if lhnetsocket then
		-- unlink from socket list
		if lhnetsocket.next == nil then
			return -- invalid!
		end
		lhnetsocket.next.prev = lhnetsocket.prev
		lhnetsocket.prev.next = lhnetsocket.next
		lhnetsocket.next = nil
		lhnetsocket.prev = nil

		-- no special close code for loopback, just inet
		local t = lhnetsocket.address.addresstype
		if t == LHNETADDRESSTYPE_INET4 or t == LHNETADDRESSTYPE_INET6 then
			local b = lhnet.backend
			if b ~= nil then
				b.close(lhnetsocket.inetsocket)
			end
		end
	end
end

-- port: lhnet.c LHNET_AddressFromSocket L1080-1086 @xonotic-v0.8.6
function lhnet.LHNET_AddressFromSocket(sock: Socket?): Address?
	if sock then
		return sock.address
	else
		return nil
	end
end

-- port: lhnet.c LHNET_Read L1088-1190 @xonotic-v0.8.6
function lhnet.LHNET_Read(lhnetsocket: Socket?, content: buffer?, maxcontentlength: number, address: Address?): number
	local value = 0
	if not lhnetsocket or not address or not content or maxcontentlength < 1 then
		return -1
	end
	local t = lhnetsocket.address.addresstype
	if t == LHNETADDRESSTYPE_LOOP then
		local currenttime
		local p, pnext
		-- scan for any old packets to timeout while searching for a packet
		-- that is waiting to be delivered to this socket
		currenttime = lhnet.time()
		local lp = lhnet.cl_netlocalping
		local localping = if lp then lp.value else 0
		p = lhnet_packetlist.next
		while p ~= lhnet_packetlist do
			local pp = p :: Packet
			pnext = pp.next
			if pp.timeout < currenttime then
				-- unlink and free
				pp.next.prev = pp.prev
				pp.prev.next = pp.next
				p = pnext
				continue
			end
			if localping ~= 0 and (prvm_edict.realtime - localping * (1.0 / 2000.0)) < pp.sentdoubletime then
				p = pnext
				continue
			end
			if value == 0 and pp.destinationport == lhnetsocket.address.port then
				if pp.length <= maxcontentlength then
					local localaddress = lhnetsocket.address
					Copy(address, localaddress)
					address.port = pp.sourceport
					buffer.copy(content, 0, pp.data, 0, pp.length)
					value = pp.length
				else
					value = -1
				end
				-- unlink and free
				pp.next.prev = pp.prev
				pp.prev.next = pp.next
			end
			p = pnext
		end
	elseif t == LHNETADDRESSTYPE_INET4 or t == LHNETADDRESSTYPE_INET6 then
		address.addresstype = LHNETADDRESSTYPE_NONE
		local b = lhnet.backend
		if b == nil then
			return 0 -- (EWOULDBLOCK: nothing ever arrives without a transport)
		end
		value = b.read(lhnetsocket.inetsocket, content, maxcontentlength, address)
		if value > 0 then
			address.addresstype = t
			return value
		elseif value < 0 then
			console.Con_DPrintf("LHNET_Read: recvfrom returned error: %s\n", "backend error")
		end
	end
	return value
end

-- port: lhnet.c LHNET_Write L1192-1242 @xonotic-v0.8.6
function lhnet.LHNET_Write(lhnetsocket: Socket?, content: buffer?, contentlength: number, address: Address?): number
	local value = -1
	if not lhnetsocket or not address or not content or contentlength < 1 then
		return -1
	end
	if lhnetsocket.address.addresstype ~= address.addresstype then
		return -1
	end
	local t = lhnetsocket.address.addresstype
	if t == LHNETADDRESSTYPE_LOOP then
		local data = buffer.create(contentlength)
		buffer.copy(data, 0, content, 0, contentlength)
		local p: Packet = {
			data = data,
			length = contentlength,
			sourceport = lhnetsocket.address.port,
			destinationport = address.port,
			timeout = lhnet.time() + 10,
			sentdoubletime = 0,
		}
		p.next = lhnet_packetlist
		p.prev = (p.next :: Packet).prev
		p.next.prev = p
		p.prev.next = p
		p.sentdoubletime = prvm_edict.realtime
		value = contentlength
	elseif t == LHNETADDRESSTYPE_INET4 or t == LHNETADDRESSTYPE_INET6 then
		local b = lhnet.backend
		if b == nil then
			return contentlength -- (no transport: the datagram goes nowhere, as an unanswered UDP send)
		end
		value = b.write(lhnetsocket.inetsocket, content, contentlength, address)
		if value == -1 then
			console.Con_DPrintf("LHNET_Write: sendto returned error: %s\n", "backend error")
		end
	end
	return value
end

return lhnet
