// Reference vectors for engine/world.luau (the entity area grid): the release's world.c compiled unchanged
// (world_vectors.sh; the physics half of the file is dropped by --gc-sections). A prog with plain edicts is
// set up here; every call and its result go to tests/vectors/world.tsv, floats as bit patterns.
#include "quakedef.h"
#include <stdint.h>

cvar_t sv_areagrid_mingridsize = {CVAR_NOTIFY, "sv_areagrid_mingridsize", "128", "minimum areagrid cell size, smaller values work better for lots of small objects, higher values for large objects"};
cvar_t developer_extra = {0, "developer_extra", "0", "prints additional debugging messages"};
void Con_Print(const char *txt) { (void)txt; }
void Con_Printf(const char *fmt, ...) { (void)fmt; }
void Con_DPrint(const char *msg) { (void)msg; }
void Con_DPrintf(const char *fmt, ...) { (void)fmt; }
// World_SetSize copies the file name with strlcpy (common.c is not linked)
size_t strlcpy(char *dst, const char *src, size_t n)
{
	size_t l = strlen(src);
	if (n)
	{
		size_t c = l >= n ? n - 1 : l;
		memcpy(dst, src, c);
		dst[c] = 0;
	}
	return l;
}

static uint32_t seed;
static uint32_t rnd(void)
{
	seed = seed * 1664525u + 1013904223u;
	return seed >> 8;
}
static float frand(float lo, float hi)
{
	return lo + (hi - lo) * ((float)(int)(rnd() % 1024) / 1024.0f);
}
static uint32_t bits(float f)
{
	uint32_t u;
	memcpy(&u, &f, 4);
	return u;
}
static void pv(const float *v)
{
	printf("\t%08x\t%08x\t%08x", bits(v[0]), bits(v[1]), bits(v[2]));
}

#define NED 320
static prvm_prog_t tv_prog;
static prvm_edict_t edicts[NED];
static edict_engineprivate_t privs[NED];
static world_t world;

static void tv_link(int n, const float *wmins, const float *wmaxs)
{
	float mins[3], maxs[3], c, e;
	int j, kind = (int)(rnd() % 16);
	for (j = 0; j < 3; j++)
	{
		// mostly inside the world box, sometimes far outside the grid
		c = frand(wmins[j], wmaxs[j]);
		if (kind == 0)
			c = c * 4;
		e = kind < 10 ? frand(1, 40) : (kind < 14 ? frand(40, 300) : frand(300, 3000)); // small / medium / huge
		mins[j] = c - e;
		maxs[j] = c + frand(0, e);
	}
	printf("L\t%d", n);
	pv(mins);
	pv(maxs);
	printf("\n");
	World_LinkEdict(&world, edicts + n, mins, maxs);
}
static void tv_query(const float *wmins, const float *wmaxs)
{
	static prvm_edict_t *list[512];
	float mins[3], maxs[3], c, e;
	int j, n, maxlist = (rnd() % 4) ? 512 : 6, kind = (int)(rnd() % 8);
	for (j = 0; j < 3; j++)
	{
		c = frand(wmins[j], wmaxs[j]);
		e = kind < 5 ? frand(0, 60) : (kind < 7 ? frand(60, 500) : frand(500, 6000));
		mins[j] = c - e;
		maxs[j] = c + e;
	}
	n = World_EntitiesInBox(&world, mins, maxs, maxlist, list);
	printf("Q");
	pv(mins);
	pv(maxs);
	printf("\t%d\t%d", maxlist, n);
	for (j = 0; j < n && j < maxlist; j++)
		printf("\t%d", (int)(list[j] - edicts));
	printf("\n");
}
static void tv_run(const float *wmins, const float *wmaxs)
{
	int i, n;
	memset(privs, 0, sizeof(privs));
	World_SetSize(&world, "testmap", wmins, wmaxs, &tv_prog);
	printf("W");
	pv(wmins);
	pv(wmaxs);
	printf("\nG");
	pv(world.areagrid_mins);
	pv(world.areagrid_maxs);
	pv(world.areagrid_size);
	pv(world.areagrid_bias);
	pv(world.areagrid_scale);
	printf("\n");
	// entity 0 is the world and is never linked
	for (i = 0; i < 240; i++)
		tv_link(i, wmins, wmaxs);
	for (i = 0; i < 20; i++)
	{
		// freed while linked: stays in the lists, is skipped by queries
		n = 1 + (int)(rnd() % 239);
		privs[n].free = true;
		printf("F\t%d\t1\n", n);
	}
	for (i = 0; i < 120; i++)
		tv_query(wmins, wmaxs);
	for (i = 0; i < 100; i++)
	{
		n = (int)(rnd() % NED);
		if (rnd() % 5 == 0)
		{
			privs[n].free = !privs[n].free;
			printf("F\t%d\t%d\n", n, (int)privs[n].free);
		}
		if (rnd() % 4 == 0)
		{
			printf("U\t%d\n", n);
			World_UnlinkEdict(edicts + n);
		}
		else
			tv_link(n, wmins, wmaxs);
	}
	for (i = 0; i < 120; i++)
		tv_query(wmins, wmaxs);
	printf("ST\t%d\t%d\t%d\t%d\n", world.areagrid_stats_calls, world.areagrid_stats_nodechecks, world.areagrid_stats_entitychecks, world.areagrid_marknumber);
	printf("UA\n");
	World_UnlinkAll(&world);
	for (i = 0; i < 6; i++)
		tv_query(wmins, wmaxs);
}

int main(void)
{
	static const float mins1[3] = {-2000, -1500, -300}, maxs1[3] = {2500, 1800, 900};
	static const float mins2[3] = {-100, -60, -20}, maxs2[3] = {90, 120, 64}; // smaller than the minimum grid
	static const float mins3[3] = {-20000.5f, -17000.25f, -4000}, maxs3[3] = {21000.75f, 9000.125f, 5000};
	int i;
	seed = 20261127u;
	sv_areagrid_mingridsize.value = 128;
	sv_areagrid_mingridsize.integer = 128;
	memset(&tv_prog, 0, sizeof(tv_prog));
	tv_prog.edicts = edicts;
	tv_prog.max_edicts = NED;
	tv_prog.num_edicts = NED;
	for (i = 0; i < NED; i++)
		edicts[i].priv.server = privs + i;
	tv_run(mins1, maxs1);
	tv_run(mins2, maxs2);
	tv_run(mins3, maxs3);
	printf("END\n");
	return 0;
}
