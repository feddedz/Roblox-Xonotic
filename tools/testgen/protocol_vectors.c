// Reference vectors for engine/protocol.luau: the release's protocol.c included as it is (to reach its statics)
// and compiled with common.c and matrixlib.c (protocol_vectors.sh). A server is set up by hand: a prog with the
// SendEntity / classname fields and the self global, a fake QuakeC SendEntity (prog->ExecuteProgram) that
// writes bytes derived from its inputs and sometimes returns false, two clients, three models with animation
// scenes (SV_GetModelByIndex) and eight skeletons. Every input and result goes to tests/vectors/protocol.tsv:
//   P*  protocol table functions
//   MD / SK / TIME / MAXCL / SE  setup lines (models, skeletons, sv.time, svs.maxclients, edict SendEntity)
//   DW / DR  EntityState5_DeltaBits + EntityState5_WriteUpdate of a state pair
//   CI / NE / CF / SALT / CW / CR / CL  EntityFrameCSQC_* (client init, num_edicts, sendflags bumps, fake QC
//            salt, WriteFrame input / result, LostFrame)
//   E5 / ME / PROTO / ES / EK / US / W5 / R5 / L5 / A5 / DG  EntityFrame5_* (database alloc, max_edicts,
//            sv.protocol, entity state, entity removed, stats update, WriteFrame input / result, LostFrame,
//            AckFrame, database digest)
//   WS / WR  Protocol_WriteStatsReliable
// Floats are printed as bit patterns, doubles as 64-bit patterns, messages as hex. Names here start with pm_.
#include "protocol.c"
#include <stdint.h>
#include <stdarg.h>

// ---- what protocol.c needs from the parts of the engine that are not linked
prvm_prog_t prvm_prog_list[PRVM_PROG_MAX]; // prvm_edict.c
server_t sv; // sv_main.c
server_static_t svs; // sv_main.c
client_t *host_client; // host.c
mempool_t *sv_mempool; // sv_main.c
cvar_t developer_networkentities = {0, "developer_networkentities", "0", "prints received entities, value is 0-10 (higher for more info, 10 being the most verbose)"}; // cl_parse.c
void Con_Print(const char *msg) { (void)msg; }
void Con_Printf(const char *fmt, ...) { (void)fmt; }
void Con_DPrint(const char *msg) { (void)msg; }
void Con_DPrintf(const char *fmt, ...) { (void)fmt; }
void Host_Error(const char *error, ...)
{
	printf("HOSTERROR\t%s\n", error);
	fflush(stdout);
	exit(1);
}
// zone.c: Mem_Alloc returns zeroed memory
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

static dp_model_t pm_models[4];
static animscene_t pm_scenes[4][6];
dp_model_t *SV_GetModelByIndex(int modelindex) // sv_main.c (sv.models[1..3] are the test models)
{
	return (modelindex > 0 && modelindex < 4) ? pm_models + modelindex : NULL;
}

// ---- random numbers and printing
static uint32_t pm_seed;
static uint32_t pm_rnd(void)
{
	pm_seed = pm_seed * 1664525u + 1013904223u;
	return pm_seed >> 8;
}
static int pm_chance(int percent)
{
	return (int)(pm_rnd() % 100) < percent;
}
static float pm_frand(float lo, float hi)
{
	return lo + (hi - lo) * ((float)(int)(pm_rnd() % 65536) / 65536.0f);
}
static uint32_t pm_fbits(float f)
{
	uint32_t u;
	memcpy(&u, &f, 4);
	return u;
}
static unsigned long long pm_dbits(double d)
{
	unsigned long long u;
	memcpy(&u, &d, 8);
	return u;
}
static void pm_hex(const unsigned char *p, int n)
{
	int i;
	putchar('\t');
	if (n <= 0)
		putchar('-');
	for (i = 0; i < n; i++)
		printf("%02x", p[i]);
}
// xorshift mixing (bit operations only, so the Luau test computes the same values exactly)
static uint32_t pm_mix(uint32_t h, uint32_t v)
{
	h ^= v;
	h ^= h << 13;
	h ^= h >> 17;
	h ^= h << 5;
	return h;
}

// ---- the prog
#define PM_NED 2048
#define PM_NF 4 // field 0 SendEntity, 1 classname
#define PM_NG 64
#define PM_GSELF 28
static prvm_edict_t pm_ed[PM_NED];
static prvm_vec_t pm_fields[PM_NED * PM_NF];
static prvm_vec_t pm_globals[PM_NG];
static uint32_t pm_salt;
static int pm_sendentity[PM_NED];

static void pm_setsendentity(int e, int v)
{
	pm_sendentity[e] = v;
	((prvm_eval_t *)(pm_ed[e].fields.fp + 0))->function = v;
	printf("SE\t%d\t%d\n", e, v);
}

// the fake SendEntity: writes bytes derived from (function, self, client entity, sendflags, salt) to
// sv.writeentitiestoclient_msg and returns true or false from the same hash
static void pm_execute(prvm_prog_t *prog, func_t fnum, const char *errormessage)
{
	int self = PRVM_serverglobaledict(self);
	int cl = PRVM_G_INT(OFS_PARM0);
	int sf = (int)PRVM_G_FLOAT(OFS_PARM1);
	uint32_t h = 2166136261u;
	int i, len;
	(void)errormessage;
	h = pm_mix(h, (uint32_t)fnum);
	h = pm_mix(h, (uint32_t)self);
	h = pm_mix(h, (uint32_t)cl);
	h = pm_mix(h, (uint32_t)sf);
	h = pm_mix(h, pm_salt);
	len = (int)(h % 23);
	if ((h >> 8) % 37 == 0)
		len = 200 + (int)(h % 300); // big enough to overflow small messages
	for (i = 0; i < len; i++)
		MSG_WriteByte(sv.writeentitiestoclient_msg, (int)(((h >> (i % 24)) + (uint32_t)i) & 255));
	PRVM_G_FLOAT(OFS_RETURN) = ((h >> 12) % 7 == 0) ? 0 : 1;
}

// ---- skeletons
static dp_model_t pm_skelmodel[2]; // num_bones 1 and 3
static matrix4x4_t pm_bones[8][3];
static void pm_skel(int k)
{
	int b, r, c;
	for (b = 0; b < 3; b++)
	{
		float x = pm_frand(-1, 1), y = pm_frand(-1, 1), z = pm_frand(-1, 1), w = pm_frand(-1, 1);
		float l = sqrtf(x * x + y * y + z * z + w * w);
		matrix4x4_t *m = &pm_bones[k][b];
		if (l < 0.01f)
		{
			x = 0; y = 0; z = 0; w = 1; l = 1;
		}
		x /= l; y /= l; z /= l; w /= l;
		m->m[0][0] = 1 - 2 * (y * y + z * z); m->m[0][1] = 2 * (x * y - z * w); m->m[0][2] = 2 * (x * z + y * w);
		m->m[1][0] = 2 * (x * y + z * w); m->m[1][1] = 1 - 2 * (x * x + z * z); m->m[1][2] = 2 * (y * z - x * w);
		m->m[2][0] = 2 * (x * z - y * w); m->m[2][1] = 2 * (y * z + x * w); m->m[2][2] = 1 - 2 * (x * x + y * y);
		m->m[0][3] = pm_frand(-300, 300); m->m[1][3] = pm_frand(-300, 300); m->m[2][3] = pm_frand(-300, 300);
		m->m[3][0] = 0; m->m[3][1] = 0; m->m[3][2] = 0; m->m[3][3] = 1;
	}
	printf("SK\t%d", k);
	for (b = 0; b < 3; b++)
		for (r = 0; r < 4; r++)
			for (c = 0; c < 4; c++)
				printf("\t%08x", pm_fbits(pm_bones[k][b].m[r][c]));
	printf("\n");
}

// ---- entity states
static void pm_ps(const entity_state_t *s)
{
	int i;
	int skel = s->skeletonobject.relativetransforms ? (int)((s->skeletonobject.relativetransforms - &pm_bones[0][0]) / 3) : -1;
	printf("\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d", s->number, s->active, s->modelindex, s->frame, s->skin, s->effects, s->flags, s->alpha, s->scale, s->colormap, s->tagentity, s->tagindex, s->viewmodelforclient, s->exteriormodelforclient, s->traileffectnum);
	printf("\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d", s->light[0], s->light[1], s->light[2], s->light[3], s->lightstyle, s->lightpflags, s->glowsize, s->glowcolor);
	printf("\t%d\t%d\t%d\t%d\t%d\t%d", s->colormod[0], s->colormod[1], s->colormod[2], s->glowmod[0], s->glowmod[1], s->glowmod[2]);
	for (i = 0; i < 3; i++)
		printf("\t%08x", pm_fbits(s->origin[i]));
	for (i = 0; i < 3; i++)
		printf("\t%08x", pm_fbits(s->angles[i]));
	for (i = 0; i < 3; i++)
		printf("\t%08x", pm_fbits(s->netcenter[i]));
	for (i = 0; i < 4; i++)
		printf("\t%d\t%08x\t%016llx", s->framegroupblend[i].frame, pm_fbits(s->framegroupblend[i].lerp), pm_dbits(s->framegroupblend[i].start));
	printf("\t%d", skel);
}

static float pm_coord(void)
{
	static const float edge[] = {-4096.0625f, -4096.0624f, -4096.07f, 4095.9375f, 4095.9374f, 4095.94f, -4095.99f, 4095.0f, 0.0f, -0.0f, 0.0625f, -0.0625f, 1e6f, -1e9f};
	int k = (int)(pm_rnd() % 100);
	if (k < 40)
		return (float)((int)(pm_rnd() % 16000) - 8000) * 0.125f;
	if (k < 75)
		return pm_frand(-4000, 4000);
	if (k < 92)
		return edge[pm_rnd() % (sizeof(edge) / sizeof(edge[0]))];
	if (k < 97)
		return pm_frand(-70000, 70000);
	return (k == 97) ? NAN : ((k == 98) ? INFINITY : -INFINITY);
}
static float pm_angle(void)
{
	int k = (int)(pm_rnd() % 100);
	if (k < 50)
		return pm_frand(-360, 360);
	if (k < 80)
		return (float)((int)(pm_rnd() % 720) - 360);
	if (k < 90)
		return pm_frand(-100000, 100000);
	if (k < 95)
		return pm_frand(-3e9f, 3e9f);
	return (k < 97) ? NAN : ((k < 99) ? INFINITY : -0.0f);
}
static int pm_effects(void)
{
	int k = (int)(pm_rnd() % 10);
	if (k < 4)
		return (int)(pm_rnd() % 256);
	if (k < 6)
		return (int)(pm_rnd() % 65536);
	if (k < 8)
		return (int)((pm_rnd() << 8) ^ pm_rnd());
	return -(int)(pm_rnd() % 70000);
}
static void pm_change(entity_state_t *s, int field, int maxent)
{
	int i;
	switch (field)
	{
	case 0: s->active = pm_chance(85) ? ACTIVE_NETWORK : (pm_chance(50) ? ACTIVE_NOT : ACTIVE_SHARED); break;
	case 1: for (i = 0; i < 3; i++) if (pm_chance(70)) s->origin[i] = pm_coord(); break;
	case 2: for (i = 0; i < 3; i++) if (pm_chance(70)) s->angles[i] = pm_angle(); break;
	case 3: s->modelindex = pm_chance(70) ? (unsigned short)(pm_rnd() % 256) : (unsigned short)(pm_rnd() % 65536); break;
	case 4: s->frame = pm_chance(70) ? (unsigned short)(pm_rnd() % 256) : (unsigned short)(pm_rnd() % 65536); break;
	case 5: s->skin = (unsigned char)pm_rnd(); break;
	case 6: s->effects = pm_effects(); break;
	case 7: s->flags = (unsigned char)(pm_rnd() & (pm_chance(50) ? 0xFF : (RENDER_LOWPRECISION | RENDER_COMPLEXANIMATION | RENDER_STEP))); break;
	case 8: s->alpha = (unsigned char)pm_rnd(); break;
	case 9: s->scale = (unsigned char)pm_rnd(); break;
	case 10: s->colormap = (unsigned char)pm_rnd(); break;
	case 11:
		s->tagentity = pm_chance(60) ? 0 : (unsigned short)(1 + pm_rnd() % (unsigned)(maxent - 1));
		s->tagindex = (unsigned char)pm_rnd();
		break;
	case 12: for (i = 0; i < 4; i++) s->light[i] = (unsigned short)pm_rnd(); s->lightstyle = (unsigned char)pm_rnd(); s->lightpflags = (unsigned char)pm_rnd(); break;
	case 13: s->glowsize = (unsigned char)pm_rnd(); if (pm_chance(50)) s->glowcolor = (unsigned char)pm_rnd(); break;
	case 14: for (i = 0; i < 3; i++) if (pm_chance(60)) s->colormod[i] = (unsigned char)pm_rnd(); break;
	case 15: for (i = 0; i < 3; i++) if (pm_chance(60)) s->glowmod[i] = (unsigned char)pm_rnd(); break;
	case 16:
		s->flags |= RENDER_COMPLEXANIMATION;
		if (pm_chance(25))
		{
			int k = (int)(pm_rnd() % 8);
			s->skeletonobject.model = pm_skelmodel + (k % 2);
			s->skeletonobject.relativetransforms = pm_bones[k];
		}
		else
		{
			s->skeletonobject.model = NULL;
			s->skeletonobject.relativetransforms = NULL;
			for (i = 0; i < 4; i++)
			{
				if (pm_chance(50))
					s->framegroupblend[i].frame = (int)(pm_rnd() % 9) - 2;
				if (pm_chance(50))
				{
					int k = (int)(pm_rnd() % 10);
					s->framegroupblend[i].lerp = k < 3 ? 0.0f : (k < 8 ? pm_frand(0, 1) : (k < 9 ? 1.0f : pm_frand(-2, 3)));
				}
				if (pm_chance(50))
					s->framegroupblend[i].start = sv.time - (double)pm_frand(-5, 200) - (pm_chance(10) ? 1e-9 : 0);
			}
		}
		break;
	case 17: s->traileffectnum = pm_chance(50) ? 0 : (unsigned short)pm_rnd(); break;
	case 18:
		s->viewmodelforclient = pm_chance(80) ? 0 : (unsigned short)(1 + pm_rnd() % 4);
		s->exteriormodelforclient = pm_chance(80) ? 0 : (unsigned short)(1 + pm_rnd() % 4);
		break;
	case 19: for (i = 0; i < 3; i++) s->netcenter[i] = pm_frand(-3000, 3000); break;
	case 20: s->flags ^= RENDER_VIEWMODEL; break;
	}
}
static void pm_randstate(entity_state_t *s, int number, int maxent)
{
	int f;
	*s = defaultstate;
	s->number = (unsigned short)number;
	s->active = ACTIVE_NETWORK;
	for (f = 0; f < 21; f++)
		if (pm_chance(f == 20 ? 5 : 35))
			pm_change(s, f, maxent);
	if (pm_chance(80))
		s->active = ACTIVE_NETWORK;
}

// ---- protocol table
static void pm_table(void)
{
	static const char *names[] = {"DP7", "dp6", "Dp5", "QUAKE", "quakedp", "qw", "NEHAHRABJP3", "DP8", "", "unknown"};
	static const int numbers[] = {3504, 3503, 3500, 97, 96, 15, 28, 250, 10000, 10002, 0, 1, 3505};
	static const size_t sizes[] = {0, 1, 2, 4, 7, 10, 30, 200};
	char buf[256];
	int i;
	for (i = 0; i < (int)(sizeof(names) / sizeof(names[0])); i++)
		printf("PE\t%s\t%d\n", names[i], (int)Protocol_EnumForName(names[i]));
	for (i = 0; i <= PROTOCOL_NEHAHRABJP3 + 1; i++)
		printf("PF\t%d\t%s\t%d\n", i, Protocol_NameForEnum((protocolversion_t)i), Protocol_NumberForEnum((protocolversion_t)i));
	for (i = 0; i < (int)(sizeof(numbers) / sizeof(numbers[0])); i++)
		printf("PN\t%d\t%d\n", numbers[i], (int)Protocol_EnumForNumber(numbers[i]));
	for (i = 0; i < (int)(sizeof(sizes) / sizeof(sizes[0])); i++)
	{
		memcpy(buf, "untouched", 10);
		Protocol_Names(buf, sizes[i]);
		printf("PS\t%d\t%s\n", (int)sizes[i], buf);
	}
}

// ---- DeltaBits / WriteUpdate
static void pm_deltawrite(int ncases)
{
	static entity_state_t o, n;
	static unsigned char data[256];
	sizebuf_t buf;
	int c, f, number, changedbits, bits;
	for (c = 0; c < ncases; c++)
	{
		int k = (int)(pm_rnd() % 10);
		pm_randstate(&o, 1 + (int)(pm_rnd() % 600), PM_NED);
		n = o;
		if (k < 2)
			pm_randstate(&n, o.number, PM_NED);
		else
			for (f = 0; f < 21; f++)
				if (pm_chance(k < 6 ? 8 : 20))
					pm_change(&n, f, PM_NED);
		if (pm_chance(20))
			o.active = pm_chance(50) ? ACTIVE_NOT : ACTIVE_SHARED;
		if (pm_chance(10))
			n.number = (unsigned short)(1 + pm_rnd() % 600);
		bits = EntityState5_DeltaBits(&o, &n);
		number = pm_chance(90) ? n.number : (int)(pm_rnd() % 40000);
		k = (int)(pm_rnd() % 10);
		changedbits = k < 6 ? bits : (k < 8 ? (int)(E5_FULLUPDATE | EntityState5_DeltaBits(&defaultstate, &n)) : (int)((pm_rnd() << 8) ^ pm_rnd()));
		memset(&buf, 0, sizeof(buf));
		buf.data = data;
		buf.maxsize = sizeof(data);
		EntityState5_WriteUpdate(number, &n, changedbits, &buf);
		printf("DW");
		pm_ps(&o);
		pm_ps(&n);
		printf("\t%d\t%d\n", number, changedbits);
		printf("DR\t%d", bits);
		pm_hex(buf.data, buf.cursize);
		printf("\n");
	}
}

// ---- CSQC entity frames
static sizebuf_t pm_msg;
static unsigned char pm_msgdata[8192];
static client_t pm_clients[2];

static void pm_csqc_init(int c)
{
	client_t *client = pm_clients + c;
	int i;
	// SV_ConnectClient (sv_main.c L922-934)
	for (i = 0; i < MAX_EDICTS; i++)
	{
		client->csqcentityscope[i] = 0;
		client->csqcentitysendflags[i] = 0xFFFFFF;
	}
	for (i = 0; i < NUM_CSQCENTITYDB_FRAMES; i++)
	{
		client->csqcentityframehistory[i].num = 0;
		client->csqcentityframehistory[i].framenum = -1;
	}
	client->csqcnumedicts = 0;
	client->csqcentityframehistory_next = 0;
	printf("CI\t%d\n", c);
}
static void pm_csqc_digest(int c)
{
	client_t *client = pm_clients + c;
	uint32_t h = 2166136261u;
	int i, j;
	printf("\t%d\t%d\t%d\t", client->csqcnumedicts, client->csqcentityframehistory_next, client->csqcentityframe_lastreset);
	for (i = 0; i < client->csqcnumedicts; i++)
		printf("%02x", client->csqcentityscope[i]);
	printf("\t");
	for (i = 0; i < client->csqcnumedicts; i++)
		printf(i ? ",%x" : "%x", client->csqcentitysendflags[i]);
	for (i = 0; i < NUM_CSQCENTITYDB_FRAMES; i++)
	{
		csqcentityframedb_t *d = client->csqcentityframehistory + i;
		h = pm_mix(h, (uint32_t)d->framenum);
		h = pm_mix(h, (uint32_t)d->num);
		for (j = 0; j < d->num; j++)
		{
			h = pm_mix(h, d->entno[j]);
			h = pm_mix(h, (uint32_t)d->sendflags[j]);
		}
	}
	printf("\t%08x", h);
}
static void pm_csqc_run(int c, int nframes, int numedicts, int lossy)
{
	prvm_prog_t *prog = SVVM_prog;
	static unsigned short numbers[MAX_EDICTS];
	static int want[MAX_EDICTS];
	int fr, i, framenum = 1 + (int)(pm_rnd() % 1000), numnumbers, maxsize, pre, ret;
	pm_csqc_init(c);
	sv.writeentitiestoclient_clientnumber = c;
	sv.writeentitiestoclient_cliententitynumber = c + 1;
	prog->num_edicts = numedicts;
	printf("NE\t%d\n", numedicts);
	for (i = 1; i < numedicts; i++)
	{
		want[i] = pm_chance(60);
		if (pm_chance(50))
			pm_setsendentity(i, want[i] ? 1 + (int)(pm_rnd() % 1000) : 0);
	}
	for (fr = 0; fr < nframes; fr++)
	{
		if (pm_chance(10) && prog->num_edicts < PM_NED - 40)
		{
			prog->num_edicts += (int)(pm_rnd() % 40);
			printf("NE\t%d\n", prog->num_edicts);
		}
		for (i = 1; i < prog->num_edicts; i++)
		{
			if (pm_chance(4))
				want[i] = !want[i];
			if (pm_chance(3))
				pm_setsendentity(i, pm_chance(80) ? 1 + (int)(pm_rnd() % 1000) : 0);
			if (pm_chance(8))
			{
				unsigned int fl = pm_chance(80) ? (1u << (pm_rnd() % 24)) : (pm_rnd() << 8);
				pm_clients[c].csqcentitysendflags[i] |= fl;
				printf("CF\t%d\t%d\t%u\n", c, i, fl);
			}
		}
		pm_salt = pm_rnd();
		printf("SALT\t%u\n", pm_salt);
		numnumbers = 0;
		for (i = 1; i < prog->num_edicts; i++)
			if (want[i])
				numbers[numnumbers++] = (unsigned short)i;
		maxsize = pm_chance(60) ? 1400 : 40 + (int)(pm_rnd() % 400);
		pre = pm_chance(70) ? 0 : (int)(pm_rnd() % 30);
		memset(&pm_msg, 0, sizeof(pm_msg));
		pm_msg.data = pm_msgdata;
		pm_msg.maxsize = pm_chance(80) ? 1450 : maxsize + (int)(pm_rnd() % 40);
		for (i = 0; i < pre; i++)
			MSG_WriteByte(&pm_msg, i);
		sv.writeentitiestoclient_msg = &pm_msg;
		printf("CW\t%d\t%d\t%d\t%d\t%d\t%d", c, maxsize, pm_msg.maxsize, pre, framenum, numnumbers);
		for (i = 0; i < numnumbers; i++)
			printf("\t%d", numbers[i]);
		printf("\n");
		ret = EntityFrameCSQC_WriteFrame(&pm_msg, maxsize, numnumbers, numbers, framenum);
		printf("CR\t%d\t%d", ret, (int)pm_msg.overflowed);
		pm_hex(pm_msg.data, pm_msg.cursize);
		pm_csqc_digest(c);
		printf("\n");
		framenum += pm_chance(95) ? 1 : 1 + (int)(pm_rnd() % 3);
		if (pm_chance(lossy))
		{
			int lf = framenum - 1 - (int)(pm_rnd() % (pm_chance(90) ? 8 : 400));
			printf("CL\t%d\t%d\n", c, lf);
			EntityFrameCSQC_LostFrame(pm_clients + c, lf);
			printf("CR\t-1\t0\t-");
			pm_csqc_digest(c);
			printf("\n");
		}
	}
}

// ---- DP5+ entity frames
static entity_state_t pm_pop[PM_NED];
static int pm_alive[PM_NED];
static const entity_state_t *pm_states[PM_NED];
static int pm_stats[MAX_CL_STATS];

static void pm_e5_digest(entityframe5_database_t *d)
{
	uint32_t h;
	int i, j;
	printf("DG\t%d\t%d\t%d\t", d->latestframenum, d->maxedicts, d->viewentnum);
	j = 0;
	for (i = 0; i < d->maxedicts; i++)
		if (d->deltabits[i] || d->priorities[i])
			printf(j++ ? ",%d:%x:%d" : "%d:%x:%d", i, (unsigned)d->deltabits[i], d->priorities[i]);
	if (!j)
		printf("-");
	h = 2166136261u;
	for (i = 0; i < d->maxedicts; i++)
		h = pm_mix(h, (uint32_t)d->updateframenum[i]);
	printf("\t%08x", h);
	h = 2166136261u;
	for (i = 0; i < (d->maxedicts + 7) / 8; i++)
		h = pm_mix(h, d->visiblebits[i]);
	printf("\t%08x\t", h);
	j = 0;
	for (i = 0; i < ENTITYFRAME5_MAXPACKETLOGS; i++)
	{
		entityframe5_packetlog_t *p = d->packetlog + i;
		int k;
		if (!p->packetnumber)
			continue;
		h = 2166136261u;
		for (k = 0; k < p->numstates; k++)
		{
			h = pm_mix(h, p->states[k].number);
			h = pm_mix(h, p->states[k].bits);
		}
		for (k = 0; k < (MAX_CL_STATS + 7) / 8; k++)
			h = pm_mix(h, p->statsdeltabits[k]);
		printf(j++ ? ",%d:%d:%d:%08x" : "%d:%d:%d:%08x", i, p->packetnumber, p->numstates, h);
	}
	if (!j)
		printf("-");
	pm_hex(host_client->statsdeltabits, (MAX_CL_STATS + 7) / 8);
	printf("\t");
	for (i = 0; i < ENTITYFRAME5_PRIORITYLEVELS; i++)
		printf(i ? ",%d" : "%d", d->prioritychaincounts[i]);
	printf("\n");
}
// EntityState5_Priority expands the database only when maxedicts < stateindex, so a tag equal to maxedicts
// would make C read past the states array: tags never equal the initial maxedicts or a multiple of 256 (the
// sizes the expansion picks), and with far tags the prog's max_edicts does not grow
// (without far tags every tag is below the prog's max_edicts, so below maxedicts)
static int pm_e5_maxedicts0, pm_e5_tagfar;
static void pm_e5_fixtag(entity_state_t *s)
{
	if (pm_e5_tagfar && s->tagentity && (s->tagentity == pm_e5_maxedicts0 || (s->tagentity & 255) == 0))
		s->tagentity++;
}
static void pm_e5_setstate(int e)
{
	pm_e5_fixtag(&pm_pop[e]);
	pm_pop[e].number = (unsigned short)e;
	printf("ES");
	pm_ps(&pm_pop[e]);
	printf("\n");
}
static void pm_e5_run(int nframes, int maxedicts, int npop, protocolversion_t protocol, int ackrate, int lossrate, int tagfar)
{
	prvm_prog_t *prog = SVVM_prog;
	entityframe5_database_t *d;
	int fr, i, numstates, maxsize, pre, ret, need_empty, viewent;
	unsigned int movesequence;
	host_client = pm_clients + 0;
	memset(host_client->stats, 0, sizeof(host_client->stats));
	memset(host_client->statsdeltabits, 0, sizeof(host_client->statsdeltabits));
	memset(pm_stats, 0, sizeof(pm_stats));
	printf("E5\n");
	d = EntityFrame5_AllocDatabase(NULL);
	sv.protocol = protocol;
	printf("PROTO\t%s\n", Protocol_NameForEnum(protocol));
	prog->max_edicts = maxedicts;
	pm_e5_maxedicts0 = maxedicts;
	pm_e5_tagfar = tagfar;
	printf("ME\t%d\n", maxedicts);
	memset(pm_alive, 0, sizeof(pm_alive));
	for (i = 0; i < npop; i++)
	{
		int e = 1 + (int)(pm_rnd() % (unsigned)(maxedicts - 1));
		if (pm_alive[e])
			continue;
		pm_alive[e] = 1;
		pm_randstate(&pm_pop[e], e, tagfar ? maxedicts + 300 : maxedicts);
		pm_e5_setstate(e);
	}
	viewent = 1;
	movesequence = pm_rnd();
	for (fr = 0; fr < nframes; fr++)
	{
		if (!tagfar && pm_chance(3) && prog->max_edicts < PM_NED - 300)
		{
			prog->max_edicts += 1 + (int)(pm_rnd() % 300);
			printf("ME\t%d\n", prog->max_edicts);
		}
		for (i = 1; i < prog->max_edicts; i++)
		{
			if (pm_alive[i])
			{
				if (pm_chance(4))
				{
					pm_alive[i] = 0;
					printf("EK\t%d\n", i);
				}
				else if (pm_chance(30))
				{
					int f, nf = 1 + (int)(pm_rnd() % 3);
					for (f = 0; f < nf; f++)
						pm_change(&pm_pop[i], (int)(pm_rnd() % 21), tagfar ? maxedicts + 300 : prog->max_edicts);
					pm_e5_setstate(i);
				}
			}
			else if (pm_chance(npop > 100 ? 2 : 1))
			{
				pm_alive[i] = 1;
				pm_randstate(&pm_pop[i], i, tagfar ? maxedicts + 300 : prog->max_edicts);
				pm_e5_setstate(i);
			}
			if (pm_chance(1))
				pm_setsendentity(i, pm_chance(70) ? 0 : 1 + (int)(pm_rnd() % 100));
		}
		if (pm_chance(30))
		{
			int k, nk = 1 + (int)(pm_rnd() % 8);
			printf("US");
			for (k = 0; k < nk; k++)
			{
				int s = (int)(pm_rnd() % MAX_CL_STATS);
				int r = (int)(pm_rnd() % 10);
				pm_stats[s] = r < 5 ? (int)(pm_rnd() % 256) : (r < 8 ? (int)((pm_rnd() << 8) ^ pm_rnd()) : -(int)(pm_rnd() % 1000));
				printf("\t%d:%d", s, pm_stats[s]);
			}
			printf("\n");
			Protocol_UpdateClientStats(pm_stats);
		}
		numstates = 0;
		for (i = 1; i < prog->max_edicts; i++)
			if (pm_alive[i])
				pm_states[numstates++] = pm_pop + i;
		maxsize = pm_chance(70) ? 1400 : 20 + (int)(pm_rnd() % 300);
		pre = pm_chance(70) ? 0 : (int)(pm_rnd() % 30);
		need_empty = pm_chance(50);
		if (pm_chance(10))
			viewent = 1 + (int)(pm_rnd() % 6);
		movesequence += pm_rnd() % 3;
		memset(&pm_msg, 0, sizeof(pm_msg));
		pm_msg.data = pm_msgdata;
		pm_msg.maxsize = 1450;
		for (i = 0; i < pre; i++)
			MSG_WriteByte(&pm_msg, i);
		printf("W5\t%d\t%d\t%d\t%u\t%d\t%d", maxsize, pre, viewent, movesequence, need_empty, numstates);
		for (i = 0; i < numstates; i++)
			printf("\t%d", pm_states[i]->number);
		printf("\n");
		ret = EntityFrame5_WriteFrame(&pm_msg, maxsize, d, numstates, pm_states, viewent, movesequence, need_empty);
		printf("R5\t%d", ret);
		pm_hex(pm_msg.data, pm_msg.cursize);
		printf("\n");
		pm_e5_digest(d);
		if (pm_chance(ackrate))
		{
			int af = d->latestframenum - (int)(pm_rnd() % 4);
			printf("A5\t%d\n", af);
			EntityFrame5_AckFrame(d, af);
			pm_e5_digest(d);
		}
		if (pm_chance(lossrate))
		{
			int lf = d->latestframenum - (int)(pm_rnd() % 6);
			printf("L5\t%d\n", lf);
			EntityFrame5_LostFrame(d, lf);
			pm_e5_digest(d);
		}
	}
	EntityFrame5_FreeDatabase(d);
}

// ---- Protocol_WriteStatsReliable
static netconn_t pm_netconn;
static unsigned char pm_netdata[4096];
static void pm_writestats(int ncases)
{
	int c, k;
	static const protocolversion_t protos[] = {PROTOCOL_QUAKE, PROTOCOL_QUAKEWORLD, PROTOCOL_DARKPLACES7};
	host_client = pm_clients + 1;
	memset(host_client->stats, 0, sizeof(host_client->stats));
	memset(host_client->statsdeltabits, 0, sizeof(host_client->statsdeltabits));
	memset(pm_stats, 0, sizeof(pm_stats));
	printf("WI\n");
	for (c = 0; c < ncases; c++)
	{
		int nk = 1 + (int)(pm_rnd() % 6);
		sv.protocol = protos[pm_rnd() % 3];
		printf("PROTO\t%s\nUS", Protocol_NameForEnum(sv.protocol));
		for (k = 0; k < nk; k++)
		{
			static const int pick[] = {11, 12, 13, 14, 16, 21, 0, 1, 15, 22, 255};
			int s = pick[pm_rnd() % (sizeof(pick) / sizeof(pick[0]))];
			int r = (int)(pm_rnd() % 10);
			pm_stats[s] = r < 5 ? (int)(pm_rnd() % 256) : (r < 8 ? (int)((pm_rnd() << 8) ^ pm_rnd()) : -(int)(pm_rnd() % 1000));
			printf("\t%d:%d", s, pm_stats[s]);
		}
		printf("\n");
		Protocol_UpdateClientStats(pm_stats);
		k = pm_chance(85);
		host_client->netconnection = k ? &pm_netconn : NULL;
		memset(&pm_netconn.message, 0, sizeof(pm_netconn.message));
		pm_netconn.message.data = pm_netdata;
		pm_netconn.message.maxsize = sizeof(pm_netdata);
		printf("WS\t%d\n", k);
		Protocol_WriteStatsReliable();
		printf("WR");
		pm_hex(pm_netconn.message.data, pm_netconn.message.cursize);
		pm_hex(host_client->statsdeltabits, (MAX_CL_STATS + 7) / 8);
		printf("\n");
	}
	host_client->netconnection = NULL;
}

int main(void)
{
	prvm_prog_t *prog = SVVM_prog;
	int i, j;
	pm_seed = 20261127u;
	memset(prog, 0, sizeof(*prog));
	prog->edicts = pm_ed;
	prog->max_edicts = PM_NED;
	prog->num_edicts = PM_NED;
	prog->entityfields = PM_NF;
	prog->edictsfields = pm_fields;
	prog->globals.fp = pm_globals;
	prog->fieldoffsets.SendEntity = 0;
	prog->fieldoffsets.classname = 1;
	prog->globaloffsets.self = PM_GSELF;
	prog->ExecuteProgram = pm_execute;
	for (i = 0; i < PM_NED; i++)
		pm_ed[i].fields.fp = pm_fields + i * PM_NF;
	svs.clients = pm_clients;
	svs.maxclients = 4;
	printf("MAXCL\t%d\n", svs.maxclients);
	sv.time = 1234.5678901234;
	printf("TIME\t%016llx\n", pm_dbits(sv.time));
	for (i = 1; i < 4; i++)
	{
		pm_models[i].animscenes = pm_scenes[i];
		pm_models[i].numframes = 6;
		printf("MD\t%d\t%d", i, pm_models[i].numframes);
		for (j = 0; j < 6; j++)
		{
			pm_scenes[i][j].framecount = (int)(pm_rnd() % 40);
			pm_scenes[i][j].framerate = pm_chance(20) ? 0.0f : pm_frand(0.5f, 60);
			printf("\t%d\t%08x", pm_scenes[i][j].framecount, pm_fbits(pm_scenes[i][j].framerate));
		}
		printf("\n");
	}
	pm_skelmodel[0].num_bones = 1;
	pm_skelmodel[1].num_bones = 3;
	for (i = 0; i < 8; i++)
		pm_skel(i);
	for (i = 0; i < 700; i++)
		if (pm_chance(15))
			pm_setsendentity(i, 1 + (int)(pm_rnd() % 1000));

	pm_table();
	pm_deltawrite(5000);
	// a skeleton changes in place (same pointers): DeltaBits must see the new matrices
	pm_skel(3);
	pm_skel(4);
	pm_deltawrite(500);

	for (i = 0; i < PM_NED; i++)
		pm_setsendentity(i, 0);
	pm_csqc_run(0, 120, 90, 25);
	pm_csqc_run(1, 80, 300, 40);
	pm_csqc_run(0, 60, 40, 60);
	pm_csqc_run(1, 40, 600, 10);

	for (i = 0; i < PM_NED; i++)
		pm_setsendentity(i, 0);
	pm_e5_run(120, 256, 60, PROTOCOL_DARKPLACES7, 70, 15, 0);
	pm_e5_run(80, 512, 200, PROTOCOL_DARKPLACES7, 40, 25, 0);
	pm_e5_run(90, 300, 40, PROTOCOL_DARKPLACES7, 0, 0, 0); // no acks: the packet log overflows
	pm_e5_run(60, 200, 50, PROTOCOL_DARKPLACES6, 60, 20, 0);
	pm_e5_run(60, 200, 50, PROTOCOL_DARKPLACES5, 60, 20, 1);
	pm_e5_run(80, 256, 90, PROTOCOL_DARKPLACES7, 60, 20, 1); // tags past maxedicts: Priority expands the database
	pm_e5_run(30, 300, 250, PROTOCOL_QUAKE, 80, 10, 0);

	pm_writestats(150);
	printf("END\n");
	return 0;
}
