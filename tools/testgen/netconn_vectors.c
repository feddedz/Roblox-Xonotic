// Reference vectors for engine/netconn.luau + engine/lhnet.luau: the release's netconn.c and lhnet.c included as
// they are (to reach their statics: the loopback packet list, NetConn_ReceivedMessage, NetConn_OpenServerPort,
// ...) and compiled with common.c and crypto.c (no d0_blind_id library is loaded, as on Roblox). netconn_vectors.sh
// builds it. Everything goes to tests/vectors/netconn.tsv as rows; the ACTION rows are the inputs (the Luau test
// replays them), every other row is a result the port must reproduce exactly:
//   actions: T (realtime, double bits), CV (cvar set), SRAND, OPENSV / OPENCL (loopback sockets), CONN (NetConn_Open),
//     CLSNETCON (cls.netcon), Q (reliable bytes into conn->message), CS (NetConn_CanSend), SEND
//     (NetConn_SendUnreliableMessage), WIRE (dump the loopback packet list), DROP / DUP / MOVE (packet list surgery),
//     RECV (NetConn_Read + NetConn_ReceivedMessage on a connection's socket), ST (connection state),
//     SV / PROG / GSTR / EDSTR / CLI / BEGUN / SVPROTO (fake server state), PKT (a raw packet from a client socket to
//     the server socket), SVFRAME (NetConn_ServerFrame), CLREAD (read a client socket), STC (state of a client's
//     netconnection), ATTACH (an INET4 netconnection put into a slot, for the timeout), CLEARSLOT, HB
//     (NetConn_Heartbeat), NETSTATS (Net_Stats_f), EXT (sv_net_extresponse)
//   results: R (return value), CA (connection address), PK (wire packet), RP (packet read), RM (ReceivedMessage
//     result), MSG (cl_message / sv_message after a complete message), CON (console output, hex), SVCC / SVSI /
//     SVRM / SVDROP (the server functions netconn.c calls, stubbed here and in the test), ST rows.
// Doubles are printed as 64-bit patterns, bytes as hex. Names here start with nv_.
#include "netconn.c"
#include "lhnet.c"
#include <stdint.h>
#include <stdarg.h>

// ---- what netconn.c / lhnet.c / crypto.c need from the parts of the engine that are not linked
double realtime; // host.c
cvar_t developer_extra = {0, "developer_extra", "0", "prints additional debugging messages, often very verbose!"}; // host.c
cvar_t teamplay = {CVAR_NOTIFY, "teamplay", "0", "teamplay mode"}; // sv_main.c
cvar_t cl_rate = {CVAR_SAVE | CVAR_NQUSERINFOHACK, "_cl_rate", "20000", "internal storage cvar for current rate (changed by rate command)"}; // host_cmd.c
cvar_t cl_rate_burstsize = {CVAR_SAVE | CVAR_NQUSERINFOHACK, "_cl_rate_burstsize", "1024", "internal storage cvar for current rate control burst size (changed by rate_burstsize command)"}; // host_cmd.c
cvar_t sv_status_privacy = {CVAR_SAVE, "sv_status_privacy", "0", "do not show IP addresses in 'status' replies to clients"}; // host_cmd.c
cvar_t rcon_password = {CVAR_PRIVATE, "rcon_password", "", "password to authenticate rcon commands"}; // host_cmd.c
cvar_t rcon_secure = {CVAR_NQUSERINFOHACK, "rcon_secure", "0", "force secure rcon authentication"}; // host_cmd.c
cvar_t rcon_secure_challengetimeout = {0, "rcon_secure_challengetimeout", "5", "challenge-based secure rcon"}; // host_cmd.c
extern cvar_t crypto_developer, crypto_aeslevel, crypto_servercpupercent, crypto_servercpumaxtime, crypto_servercpudebug;
client_static_t cls; // cl_main.c
server_t sv; // sv_main.c
server_static_t svs; // sv_main.c
client_t *host_client; // host.c
prvm_prog_t prvm_prog_list[PRVM_PROG_MAX]; // prvm_edict.c
mempool_t *zonemempool; // zone.c (Z_Malloc of lhnet.c reads it)

static void nv_hex(const unsigned char *p, int n)
{
	int i;
	putchar('\t');
	if (n <= 0)
		putchar('-');
	for (i = 0; i < n; i++)
		printf("%02x", p[i]);
}
static void nv_hexs(const char *s)
{
	nv_hex((const unsigned char *)s, (int)strlen(s));
}
static unsigned long long nv_dbits(double d)
{
	unsigned long long u;
	memcpy(&u, &d, 8);
	return u;
}

void Con_Print(const char *msg)
{
	printf("CON");
	nv_hexs(msg);
	printf("\n");
}
void Con_Printf(const char *fmt, ...)
{
	char buf[16384];
	va_list a;
	va_start(a, fmt);
	dpvsnprintf(buf, sizeof(buf), fmt, a);
	va_end(a);
	Con_Print(buf);
}
void Con_DPrint(const char *msg) { (void)msg; } // developer 0
void Con_DPrintf(const char *fmt, ...) { (void)fmt; }
void Host_Error(const char *error, ...)
{
	printf("HOSTERROR\t%s\n", error);
	fflush(stdout);
	exit(1);
}
void *_Mem_Alloc(mempool_t *pool, void *data, size_t size, size_t alignment, const char *filename, int fileline)
{
	(void)pool; (void)data; (void)alignment; (void)filename; (void)fileline;
	return calloc(1, size);
}
void _Mem_Free(void *data, const char *filename, int fileline)
{
	(void)filename; (void)fileline;
	free(data);
}
mempool_t *_Mem_AllocPool(const char *name, int flags, mempool_t *parent, const char *filename, int fileline)
{
	(void)name; (void)flags; (void)parent; (void)filename; (void)fileline;
	return NULL;
}
void Cmd_AddCommand(const char *cmd_name, xcommand_t function, const char *description) { (void)cmd_name; (void)function; (void)description; }
void Cvar_RegisterVariable(cvar_t *variable)
{
	variable->value = atof(variable->string);
	variable->integer = (int)variable->value;
}
static void nv_cvarset(cvar_t *var, const char *value)
{
	var->string = strdup(value);
	var->value = atof(var->string);
	var->integer = (int)var->value;
}
void Cvar_SetQuick(cvar_t *var, const char *value) { nv_cvarset(var, value); }
void Cvar_SetValueQuick(cvar_t *var, float value)
{
	char v[64];
	if ((float)(int)value == value)
		dpsnprintf(v, sizeof(v), "%i", (int)value);
	else
		dpsnprintf(v, sizeof(v), "%f", value);
	nv_cvarset(var, v);
}
qboolean Thread_HasThreads(void) { return false; }
double Sys_DirtyTime(void) { return 0; }

// the prog: strings for worldstatus / clientstatus
static char nv_strings[4096];
static int nv_stringssize = 1;
static prvm_vec_t nv_globals[64];
static prvm_vec_t nv_fields[16 * 4];
static prvm_edict_t nv_edicts[16];
const char *PRVM_GetString(prvm_prog_t *prog, int num)
{
	(void)prog;
	return (num >= 0 && num < nv_stringssize) ? nv_strings + num : "";
}

// the server functions netconn.c calls: recorded (tests/unit/netconn_ref.test.luau has the same stubs)
void SV_ConnectClient(int clientnum, netconn_t *netconnection)
{
	client_t *c = svs.clients + clientnum;
	printf("SVCC\t%d\t%s\n", clientnum, netconnection->address);
	c->active = true;
	c->netconnection = netconnection;
	strlcpy(c->name, "unconnected", sizeof(c->name));
	c->begun = false;
	c->ping = 0;
	c->frags = 0;
	c->colors = 0;
	c->connecttime = realtime;
}
void SV_SendServerinfo(client_t *client)
{
	printf("SVSI\t%d\n", (int)(client - svs.clients));
}
void SV_ReadClientMessage(void)
{
	printf("SVRM\t%d", (int)(host_client - svs.clients));
	nv_hex(sv_message.data, sv_message.cursize);
	printf("\t%d\t%d\n", sv_message.readcount, sv_message.badread);
}
void SV_DropClient(qboolean crash)
{
	printf("SVDROP\t%d\t%d\n", (int)(host_client - svs.clients), crash);
	NetConn_Close(host_client->netconnection);
	host_client->netconnection = NULL;
	host_client->active = false;
}

// ---- the cvars the scenario sets, by name
static cvar_t *nv_cvars[] = {
	&sv_public, &sv_public_rejectreason, &sv_heartbeatperiod, &sv_masters[0], &sv_masters[1], &sv_masters[2],
	&sv_masters[3], &sv_masters[4], &sv_masters[5], &sv_masters[6], &net_test, &net_messagetimeout,
	&net_connecttimeout, &net_connectfloodblockingtimeout, &net_challengefloodblockingtimeout,
	&net_getstatusfloodblockingtimeout, &hostname, &developer_networking, &cl_netlocalping, &gameversion,
	&developer_extra, &teamplay, &cl_rate, &cl_rate_burstsize, &sv_status_privacy, &rcon_secure, NULL};
static void nv_cv(const char *name, const char *value)
{
	int i;
	for (i = 0; nv_cvars[i]; i++)
		if (!strcmp(nv_cvars[i]->name, name))
		{
			printf("CV\t%s", name);
			nv_hexs(value);
			printf("\n");
			nv_cvarset(nv_cvars[i], value);
			return;
		}
	printf("BADCVAR\t%s\n", name);
	exit(1);
}

// ---- deterministic choices
static uint32_t nv_seed = 12345;
static uint32_t nv_rnd(void)
{
	nv_seed = nv_seed * 1664525u + 1013904223u;
	return nv_seed >> 8;
}
static int nv_chance(int percent)
{
	return (int)(nv_rnd() % 100) < percent;
}

static void nv_time(double t)
{
	realtime = t;
	printf("T\t%016llx\n", nv_dbits(t));
}

// ---- sockets and connections
static lhnetsocket_t *nv_svsock;
static netconn_t *nv_conns[8];
static int nv_numconns;

static void nv_opensv(int port)
{
	qboolean r = NetConn_OpenServerPort(NULL, LHNETADDRESSTYPE_LOOP, port, 0);
	printf("OPENSV\t%d\nR\t%d\n", port, r);
	nv_svsock = sv_sockets[sv_numsockets - 1];
}
static void nv_opencl(int port)
{
	printf("OPENCL\t%d\n", port);
	NetConn_OpenClientPort(NULL, LHNETADDRESSTYPE_LOOP, port);
	printf("R\t%d\n", cl_numsockets);
}
// conn on the server socket (side 0) or client socket k (side k + 1), to the loopback peer port
static int nv_conn(int side, int peerport)
{
	lhnetaddress_t a;
	netconn_t *c;
	LHNETADDRESS_FromPort(&a, LHNETADDRESSTYPE_LOOP, peerport);
	printf("CONN\t%d\t%d\n", side, peerport);
	c = NetConn_Open(side == 0 ? nv_svsock : cl_sockets[side - 1], &a);
	nv_conns[nv_numconns] = c;
	printf("CA\t%d\t%s\n", nv_numconns, c->address);
	return nv_numconns++;
}

static void nv_state(const char *tag, int id, netconn_t *c)
{
	netgraphitem_t *og = &c->outgoing_netgraph[c->outgoing_packetcounter];
	netgraphitem_t *ig = &c->incoming_netgraph[c->incoming_packetcounter];
	printf("%s\t%d\t%u\t%u\t%u\t%u\t%u\t%d\t%d\t%d", tag, id, c->nq.sendSequence, c->nq.ackSequence, c->nq.receiveSequence,
		c->nq.unreliableReceiveSequence, c->outgoing_unreliable_sequence, c->sendMessageLength, c->receiveMessageLength,
		c->message.cursize);
	printf("\t%016llx\t%016llx\t%016llx\t%016llx\t%016llx", nv_dbits(c->cleartime), nv_dbits(c->incoming_cleartime),
		nv_dbits(c->lastSendTime), nv_dbits(c->lastMessageTime), nv_dbits(c->timeout));
	printf("\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d", c->packetsSent, c->packetsReSent, c->packetsReceived,
		c->receivedDuplicateCount, c->droppedDatagrams, c->unreliableMessagesSent, c->unreliableMessagesReceived,
		c->reliableMessagesSent, c->reliableMessagesReceived);
	printf("\t%d\t%d\t%d\t%d\t%d\t%016llx\t%016llx", c->outgoing_packetcounter, c->incoming_packetcounter,
		og->unreliablebytes, og->reliablebytes, og->ackbytes, nv_dbits(og->cleartime), nv_dbits(og->time));
	printf("\t%d\t%d\t%d\t%016llx\t%016llx\n", ig->unreliablebytes, ig->reliablebytes, ig->ackbytes,
		nv_dbits(ig->cleartime), nv_dbits(ig->time));
}
static void nv_st(int id)
{
	printf("ST\t%d\n", id);
	nv_state("S", id, nv_conns[id]);
}

static unsigned char nv_data[NET_MAXMESSAGE];
static void nv_fill(int n)
{
	int i;
	for (i = 0; i < n; i++)
		nv_data[i] = (unsigned char)nv_rnd();
}
static void nv_q(int id, int n)
{
	netconn_t *c = nv_conns[id];
	nv_fill(n);
	printf("Q\t%d", id);
	nv_hex(nv_data, n);
	printf("\n");
	SZ_Write(&c->message, nv_data, n);
}
static void nv_cs(int id)
{
	printf("CS\t%d\n", id);
	printf("R\t%d\n", NetConn_CanSend(nv_conns[id]));
}
static void nv_send(int id, int n, int rate, int burst, int suppress)
{
	sizebuf_t msg;
	unsigned char buf[2048];
	int r;
	memset(&msg, 0, sizeof(msg));
	msg.data = buf;
	msg.maxsize = sizeof(buf);
	nv_fill(n);
	memcpy(buf, nv_data, n);
	msg.cursize = n;
	printf("SEND\t%d", id);
	nv_hex(buf, n);
	printf("\t%d\t%d\t%d\n", rate, burst, suppress);
	r = NetConn_SendUnreliableMessage(nv_conns[id], &msg, PROTOCOL_DARKPLACES7, rate, burst, suppress);
	printf("R\t%d\n", r);
}
static int nv_npackets(void)
{
	int n = 0;
	lhnetpacket_t *p;
	for (p = lhnet_packetlist.next; p != &lhnet_packetlist; p = p->next)
		n++;
	return n;
}
static lhnetpacket_t *nv_packet(int i)
{
	lhnetpacket_t *p;
	for (p = lhnet_packetlist.next; p != &lhnet_packetlist; p = p->next)
		if (i-- == 0)
			return p;
	return NULL;
}
static void nv_wire(void)
{
	lhnetpacket_t *p;
	int i = 0;
	printf("WIRE\n");
	printf("W\t%d\n", nv_npackets());
	for (p = lhnet_packetlist.next; p != &lhnet_packetlist; p = p->next, i++)
	{
		printf("PK\t%d\t%d\t%d", i, p->sourceport, p->destinationport);
		nv_hex((unsigned char *)p->data, p->length);
		printf("\n");
	}
}
static void nv_unlink(lhnetpacket_t *p)
{
	p->next->prev = p->prev;
	p->prev->next = p->next;
}
static void nv_append(lhnetpacket_t *p)
{
	p->next = &lhnet_packetlist;
	p->prev = p->next->prev;
	p->next->prev = p;
	p->prev->next = p;
}
static void nv_surgery(void)
{
	int n = nv_npackets(), i;
	lhnetpacket_t *p;
	if (n == 0)
		return;
	if (nv_chance(12))
	{
		i = (int)(nv_rnd() % n);
		printf("DROP\t%d\n", i);
		p = nv_packet(i);
		nv_unlink(p);
		Z_Free(p);
		n--;
	}
	if (n > 0 && nv_chance(6))
	{
		lhnetpacket_t *q;
		i = (int)(nv_rnd() % n);
		printf("DUP\t%d\n", i);
		p = nv_packet(i);
		q = (lhnetpacket_t *)Z_Malloc(sizeof(*q) + p->length);
		*q = *p;
		q->data = (void *)(q + 1);
		memcpy(q->data, p->data, p->length);
		// insert after p
		q->prev = p;
		q->next = p->next;
		p->next->prev = q;
		p->next = q;
		n++;
	}
	if (n > 1 && nv_chance(8))
	{
		i = (int)(nv_rnd() % n);
		printf("MOVE\t%d\n", i);
		p = nv_packet(i);
		nv_unlink(p);
		nv_append(p);
	}
}
static void nv_recv(int id, double newtimeout)
{
	netconn_t *c = nv_conns[id];
	static unsigned char buf[NET_HEADERSIZE + NET_MAXMESSAGE];
	lhnetaddress_t peer;
	int len, r;
	printf("RECV\t%d\t%016llx\n", id, nv_dbits(newtimeout));
	while ((len = NetConn_Read(c->mysocket, buf, sizeof(buf), &peer)) > 0)
	{
		printf("RP\t%d\t%d", len, LHNETADDRESS_GetPort(&peer));
		nv_hex(buf, len);
		printf("\n");
		r = NetConn_ReceivedMessage(c, buf, len, PROTOCOL_DARKPLACES7, newtimeout);
		printf("RM\t%d\n", r);
		if (r == 2)
		{
			sizebuf_t *m = (c == cls.netcon) ? &cl_message : &sv_message;
			printf("MSG\t%d", c == cls.netcon);
			nv_hex(m->data, m->cursize);
			printf("\t%d\t%d\n", m->readcount, m->badread);
		}
	}
}

// ---- scenario A: two connections back to back
static void nv_side(int id, int rate, int burst, int bigchance)
{
	netconn_t *c = nv_conns[id];
	// queue reliable messages (several may wait in conn->message while one is in flight)
	if (nv_chance(30) && c->message.cursize < 50000)
	{
		int n;
		if (nv_chance(bigchance))
			n = 1025 + (int)(nv_rnd() % 4000);
		else if (nv_chance(10))
			n = 1024;
		else
			n = 1 + (int)(nv_rnd() % 300);
		nv_q(id, n);
	}
	nv_cs(id);
	if (c->outgoing_netgraph[c->outgoing_packetcounter].unreliablebytes != NETGRAPH_CHOKEDPACKET || nv_chance(10))
	{
		int n = nv_chance(15) ? 0 : (nv_chance(10) ? 1000 + (int)(nv_rnd() % 400) : 1 + (int)(nv_rnd() % 120));
		nv_send(id, n, rate, burst, nv_chance(8));
	}
}

static void nv_scenario_a(void)
{
	int f, a, b;
	double t = 1.0;
	nv_opensv(1);
	nv_opencl(2);
	a = nv_conn(0, 2);
	b = nv_conn(1, 1);
	printf("CLSNETCON\t%d\n", b);
	cls.netcon = nv_conns[b];
	nv_st(a);
	nv_st(b);
	for (f = 0; f < 260; f++)
	{
		// time steps: mostly a frame, sometimes a stall (fragment resend after 1 s)
		if (f % 50 == 49)
			t += 1.25;
		else
			t += (double)(1 + nv_rnd() % 5) * 0.0125;
		nv_time(t);
		if (f == 120)
			nv_cv("net_test", "1");
		if (f == 160)
			nv_cv("net_test", "0");
		nv_side(a, f < 100 ? 25000 : 9000, f < 100 ? 2000 : 0, 25);
		nv_side(b, 20000, 1024, 10);
		if (nv_chance(30))
			nv_wire();
		nv_surgery();
		if (!nv_chance(15))
			nv_recv(a, 300.0);
		if (!nv_chance(15))
			nv_recv(b, 15.0);
		nv_st(a);
		nv_st(b);
	}
	// drain
	for (f = 0; f < 40; f++)
	{
		t += 0.5;
		nv_time(t);
		nv_cs(a);
		nv_send(a, 0, 25000, 0, 0);
		nv_cs(b);
		nv_send(b, 0, 25000, 0, 0);
		nv_recv(a, 300.0);
		nv_recv(b, 15.0);
		nv_st(a);
		nv_st(b);
	}
	printf("CLSNETCON\t-1\n");
	cls.netcon = NULL;
}

// ---- scenario B: connectionless server packets and per-client routing
static unsigned char nv_last[NET_HEADERSIZE + NET_MAXMESSAGE];
static char nv_chal[8][64]; // the last challenge each client socket received
static void nv_clread(int k)
{
	lhnetaddress_t peer;
	int len;
	printf("CLREAD\t%d\n", k);
	while ((len = NetConn_Read(cl_sockets[k], nv_last, sizeof(nv_last), &peer)) > 0)
	{
		printf("RP\t%d\t%d", len, LHNETADDRESS_GetPort(&peer));
		nv_hex(nv_last, len);
		printf("\n");
		if (len > 14 && !memcmp(nv_last, "\377\377\377\377challenge ", 14))
		{
			nv_last[len - 1] = 0;
			strlcpy(nv_chal[k], (const char *)nv_last + 14, sizeof(nv_chal[k]));
		}
	}
}
static void nv_connect(int k, const char *protocol, const char *extra)
{
	char s[512];
	dpsnprintf(s, sizeof(s), "connect\\protocol\\%s\\challenge\\%s%s", protocol, nv_chal[k], extra);
	{
		char buf[4096];
		int n = dpsnprintf(buf, sizeof(buf), "\377\377\377\377%s", s);
		lhnetaddress_t a;
		LHNETADDRESS_FromPort(&a, LHNETADDRESSTYPE_LOOP, 1);
		printf("PKT\t%d", k);
		nv_hex((const unsigned char *)buf, n);
		printf("\n");
		NetConn_Write(cl_sockets[k], buf, n, &a);
	}
}
static void nv_clix(int slot, int frags, int colors, float ping)
{
	client_t *c = svs.clients + slot;
	uint32_t pb;
	memcpy(&pb, &ping, 4);
	printf("CLIX\t%d\t%d\t%d\t%08x\n", slot, frags, colors, pb);
	c->frags = frags;
	c->colors = colors;
	c->ping = ping;
}
static void nv_pkt(int k, const unsigned char *data, int len)
{
	lhnetaddress_t a;
	LHNETADDRESS_FromPort(&a, LHNETADDRESSTYPE_LOOP, 1);
	printf("PKT\t%d", k);
	nv_hex(data, len);
	printf("\n");
	NetConn_Write(cl_sockets[k], data, len, &a);
}
static void nv_pkts(int k, const char *s)
{
	char buf[4096];
	int n = dpsnprintf(buf, sizeof(buf), "\377\377\377\377%s", s);
	nv_pkt(k, (const unsigned char *)buf, n);
}
static void nv_svframe(void)
{
	printf("SVFRAME\n");
	NetConn_ServerFrame();
}
static void nv_stc(int slot)
{
	printf("STC\t%d\n", slot);
	if (svs.clients[slot].netconnection)
		nv_state("S", slot, svs.clients[slot].netconnection);
	else
		printf("S\t%d\t-\n", slot);
}
static void nv_prog(void)
{
	prvm_prog_t *prog = SVVM_prog;
	int i;
	static const char *strs[] = {"gametype dm, 3 players\\ with \\ and\nnewline", "frag:7 \"q\"\tx", "spec", ""};
	int ofs[4];
	nv_stringssize = 1;
	for (i = 0; i < 4; i++)
	{
		ofs[i] = nv_stringssize;
		memcpy(nv_strings + nv_stringssize, strs[i], strlen(strs[i]) + 1);
		nv_stringssize += (int)strlen(strs[i]) + 1;
	}
	printf("PROG");
	nv_hex((unsigned char *)nv_strings, nv_stringssize);
	printf("\t%d\n", 16);
	memset(prog, 0, sizeof(*prog));
	prog->globals.fp = nv_globals;
	prog->globaloffsets.worldstatus = 28;
	prog->fieldoffsets.clientstatus = 1;
	prog->max_edicts = 16;
	for (i = 0; i < 16; i++)
		nv_edicts[i].fields.fp = nv_fields + i * 4;
	prog->edicts = nv_edicts;
	printf("GSTR\t%d\n", ofs[0]);
	((prvm_eval_t *)(nv_globals + 28))->string = ofs[0];
	printf("EDSTR\t%d\t%d\n", 2, ofs[1]);
	((prvm_eval_t *)(nv_fields + 2 * 4 + 1))->string = ofs[1];
	printf("EDSTR\t%d\t%d\n", 3, ofs[2]);
	((prvm_eval_t *)(nv_fields + 3 * 4 + 1))->string = ofs[2];
}
static void nv_cli(int slot, const char *name, int frags, int colors, float ping)
{
	client_t *c = svs.clients + slot;
	uint32_t pb;
	memcpy(&pb, &ping, 4);
	printf("CLI\t%d", slot);
	nv_hexs(name);
	printf("\t%d\t%d\t%08x\n", frags, colors, pb);
	c->active = true;
	c->netconnection = NULL;
	strlcpy(c->name, name, sizeof(c->name));
	c->frags = frags;
	c->colors = colors;
	c->ping = ping;
}
// a NetQuake / DarkPlaces data packet of a connected client (header + payload)
static void nv_datapkt(int k, unsigned int flags, unsigned int seq, int n)
{
	unsigned char buf[2048];
	StoreBigLong(buf, (8 + n) | flags);
	StoreBigLong(buf + 4, seq);
	nv_fill(n);
	memcpy(buf + 8, nv_data, n);
	nv_pkt(k, buf, 8 + n);
}
static void nv_ctlpkt(int k, const unsigned char *body, int n)
{
	unsigned char buf[512];
	StoreBigLong(buf, NETFLAG_CTL | (4 + n));
	memcpy(buf + 4, body, n);
	nv_pkt(k, buf, 4 + n);
}

static void nv_scenario_b(void)
{
	char s[4096];
	double t = 100.0;
	int i;
	nv_time(t);
	printf("SRAND\t%d\n", 4242);
	srand(4242);
	sv.active = true;
	sv.protocol = PROTOCOL_DARKPLACES7;
	strlcpy(sv.worldbasename, "stormkeep", sizeof(sv.worldbasename));
	strlcpy(sv.name, "stormkeep", sizeof(sv.name));
	svs.maxclients = 3;
	svs.clients = (client_t *)calloc(svs.maxclients, sizeof(client_t));
	printf("SV\t%d\t%d\t%s\t%s\n", svs.maxclients, sv.protocol, sv.worldbasename, sv.name);
	nv_prog();
	nv_cli(0, "[BOT]Al\\ph\"a", 5, 0x44, 0.0f);
	nv_opencl(3);
	nv_opencl(4);
	nv_opencl(5);
	nv_opencl(7);
	// k: cl_sockets index (0 = port 2 of scenario A, 1 = port 3, 2 = port 4, 3 = port 5, 4 = port 7)

	// getchallenge, flood control, the same challenge again
	nv_pkts(1, "getchallenge");
	nv_svframe();
	nv_clread(1);
	nv_time(t += 0.1);
	nv_pkts(1, "getchallenge");
	nv_svframe();
	nv_clread(1);
	nv_time(t += 0.6);
	nv_pkts(1, "getchallenge");
	nv_svframe();
	nv_clread(1);
	// connect: bad challenge (dropped), wrong protocol, good
	nv_time(t += 0.1);
	nv_pkts(1, "connect\\protocol\\darkplaces 3\\challenge\\wrongwrong1");
	nv_svframe();
	nv_clread(1);
	nv_connect(1, "darkplaces 2", "");
	nv_svframe();
	nv_clread(1);
	nv_connect(1, "darkplaces 3", "\\message\\hello");
	nv_svframe();
	nv_clread(1);
	nv_stc(1);
	// duplicate connect (not begun), then begun (serverinfo again)
	nv_connect(1, "darkplaces 3", "");
	nv_svframe();
	nv_clread(1);
	printf("BEGUN\t1\t1\n");
	svs.clients[1].begun = true;
	nv_connect(1, "darkplaces 3", "");
	nv_svframe();
	nv_clread(1);
	// a second client within the connect flood time (dropped), then after it
	nv_pkts(2, "getchallenge");
	nv_time(t += 0.6);
	nv_svframe();
	nv_clread(2);
	nv_connect(2, "darkplaces 3", "");
	nv_svframe();
	nv_clread(2);
	nv_time(t += 6.0);
	nv_connect(2, "darkplaces 3", "");
	nv_svframe();
	nv_clread(2);
	nv_stc(2);
	// server full; a connect without a challenge key is not checked
	nv_pkts(3, "getchallenge");
	nv_time(t += 6.0);
	nv_svframe();
	nv_clread(3);
	nv_connect(3, "darkplaces 3", "");
	nv_svframe();
	nv_clread(3);
	nv_time(t += 6.0);
	nv_pkts(3, "connect\\protocol\\darkplaces 3");
	nv_svframe();
	nv_clread(3);
	// getinfo / getstatus (with and without challenge), getstatus flood
	nv_time(t += 2.0);
	nv_pkts(3, "getinfo abc123");
	nv_svframe();
	nv_clread(3);
	nv_time(t += 2.0);
	nv_pkts(3, "getstatus");
	nv_svframe();
	nv_clread(3);
	nv_pkts(3, "getstatus again");
	nv_svframe();
	nv_clread(3);
	nv_cv("teamplay", "1");
	nv_clix(1, 3, 0xDD, 0.0375f);
	nv_clix(2, -666, 0x44, 12.5f);
	nv_time(t += 2.0);
	nv_pkts(3, "getstatus xyz");
	nv_svframe();
	nv_clread(3);
	// a hostname long enough that the player lines do not fit: infoResponse conversion
	memset(s, 'h', 2660);
	s[2660] = 0;
	nv_cv("hostname", s);
	nv_time(t += 2.0);
	nv_pkts(3, "getstatus");
	nv_svframe();
	nv_clread(3);
	// and too long for the header: no reply
	memset(s, 'h', 2900);
	s[2900] = 0;
	nv_cv("hostname", s);
	nv_time(t += 2.0);
	nv_pkts(3, "getinfo");
	nv_svframe();
	nv_clread(3);
	nv_cv("hostname", "Test Server");
	nv_cv("teamplay", "0");
	// ping, ack, extResponse, unknown
	nv_pkts(3, "ping");
	nv_pkts(3, "ack");
	nv_pkts(3, "extResponse hello world");
	nv_pkts(3, "extResponse second");
	nv_pkts(3, "whatever");
	nv_svframe();
	nv_clread(3);
	printf("EXT\n");
	printf("X\t%d\t%d", sv_net_extresponse_count, sv_net_extresponse_last);
	nv_hexs(sv_net_extresponse[sv_net_extresponse_last]);
	printf("\n");
	// client 1 (slot 1) sends unreliable and reliable data: SV_ReadClientMessage, acks
	nv_time(t += 0.05);
	nv_datapkt(1, NETFLAG_UNRELIABLE, 0, 20);
	nv_datapkt(1, NETFLAG_UNRELIABLE, 3, 10);
	nv_datapkt(1, NETFLAG_UNRELIABLE, 2, 10);
	nv_datapkt(1, NETFLAG_DATA, 0, 40);
	nv_datapkt(1, NETFLAG_DATA | NETFLAG_EOM, 1, 30);
	nv_datapkt(1, NETFLAG_DATA | NETFLAG_EOM, 1, 30);
	nv_datapkt(1, NETFLAG_DATA | NETFLAG_EOM, 2, 5);
	nv_datapkt(1, NETFLAG_UNRELIABLE, 4, 0);
	nv_svframe();
	nv_clread(1);
	nv_stc(1);
	// the server sends to slot 1 (reliable fragments) and slot 1 acks them
	{
		netconn_t *c = svs.clients[1].netconnection;
		nv_fill(3000);
		printf("SVQ\t1");
		nv_hex(nv_data, 3000);
		printf("\n");
		SZ_Write(&c->message, nv_data, 3000);
		for (i = 0; i < 4; i++)
		{
			sizebuf_t msg;
			unsigned char buf[64];
			memset(&msg, 0, sizeof(msg));
			msg.data = buf;
			msg.maxsize = sizeof(buf);
			MSG_WriteByte(&msg, 1);
			printf("SVSEND\t1\n");
			printf("R\t%d\n", NetConn_SendUnreliableMessage(c, &msg, sv.protocol, 1000000, 0, false));
			nv_clread(1);
			nv_datapkt(1, NETFLAG_ACK, c->nq.sendSequence - 1, 0);
			nv_svframe();
			nv_stc(1);
		}
	}
	// NetQuake control packets (sv.protocol QUAKE): server info, player info, incompatible connect
	printf("SVPROTO\t%d\n", PROTOCOL_QUAKE);
	sv.protocol = PROTOCOL_QUAKE;
	nv_time(t += 2.0);
	nv_ctlpkt(3, (const unsigned char *)"\002QUAKE\000\003", 8);
	nv_svframe();
	nv_clread(3);
	nv_time(t += 2.0);
	nv_ctlpkt(3, (const unsigned char *)"\003\001", 2);
	nv_svframe();
	nv_clread(3);
	nv_time(t += 2.0);
	nv_ctlpkt(3, (const unsigned char *)"\001QUAKE\000\002", 8);
	nv_svframe();
	nv_clread(3);
	printf("SVPROTO\t%d\n", PROTOCOL_DARKPLACES7);
	sv.protocol = PROTOCOL_DARKPLACES7;
	// heartbeat to a loopback "master"
	nv_cv("sv_public", "1");
	nv_cv("sv_master1", "local:7");
	printf("HB\t2\n");
	NetConn_Heartbeat(2);
	nv_clread(4);
	printf("HB\t1\n");
	NetConn_Heartbeat(1);
	nv_clread(4);
	nv_time(t += 200.0);
	printf("HB\t0\n");
	NetConn_Heartbeat(0);
	nv_clread(4);
	nv_cv("sv_public", "0");
	// timeout of a non-loopback client (slot 2 becomes an INET4 connection)
	printf("CLEARSLOT\t2\n");
	NetConn_Close(svs.clients[2].netconnection);
	svs.clients[2].netconnection = NULL;
	svs.clients[2].active = false;
	{
		lhnetaddress_t a;
		LHNETADDRESS_FromString(&a, "10.1.2.3:27001", 26000);
		printf("ATTACH\t2\t10.1.2.3:27001\n");
		svs.clients[2].netconnection = NetConn_Open(nv_svsock, &a);
		svs.clients[2].active = true;
		printf("CA\t2\t%s\n", svs.clients[2].netconnection->address);
		nv_stc(2);
	}
	nv_time(t += 10.0);
	nv_svframe();
	nv_time(t += 10.0);
	nv_svframe();
	nv_stc(2);
	printf("NETSTATS\n");
	Net_Stats_f();
}

int main(void)
{
	gamemode = GAME_XONOTIC;
	gamenetworkfiltername = "Xonotic";
	strlcpy(com_modname, "data", sizeof(com_modname));
	NetConn_Init();
	Cvar_RegisterVariable(&developer_extra);
	Cvar_RegisterVariable(&teamplay);
	Cvar_RegisterVariable(&cl_rate);
	Cvar_RegisterVariable(&cl_rate_burstsize);
	Cvar_RegisterVariable(&sv_status_privacy);
	Cvar_RegisterVariable(&rcon_secure);
	Cvar_RegisterVariable(&crypto_developer);
	Cvar_RegisterVariable(&crypto_aeslevel);
	Cvar_RegisterVariable(&crypto_servercpupercent);
	Cvar_RegisterVariable(&crypto_servercpumaxtime);
	Cvar_RegisterVariable(&crypto_servercpudebug);
	nv_cv("sv_public", "0");
	nv_cv("hostname", "Test Server");
	nv_cv("gameversion", "806");
	nv_cv("net_connecttimeout", "15");
	nv_cv("net_messagetimeout", "300");
	nv_cv("sv_master1", "");
	nv_cv("sv_masterextra1", "");
	nv_cv("sv_masterextra2", "");
	nv_cv("sv_masterextra3", "");
	nv_time(1.0);
	nv_scenario_a();
	nv_scenario_b();
	printf("END\n");
	return 0;
}
