// Reference vectors for the Q3 shader script code of engine/model_shared.luau: the release's model_shared.c is
// included unchanged (so the static q3shader_data hash can be walked) and linked with common.c (the real
// COM_ParseToken_QuakeC, com_token, strlcpy, dpsnprintf, CRC_Block_CaseInsensitive); unused functions are dropped
// by --gc-sections (shader_vectors.sh). The real Mod_LoadQ3Shaders runs on tests/fixtures/shaders/scripts/ (no
// game data), twice with different cvar settings; after each load every field of every q3shaderinfo_t in the
// hash is printed (bucket then chain order), then the real Mod_LoadTextureFromQ3Shader is run on a list of
// texture names and every field it sets is printed. Floats are printed as bit patterns, strings escaped
// (\\ \t \n \r \xHH). All names here start with tv_ because they share a translation unit with model_shared.c.
#include "model_shared.c"
#include <stdint.h>
#include <dirent.h>

// ---- what the linked code needs from the rest of the engine
client_static_t cls;
mempool_t *tempmempool;
cvar_t developer_extra = {0, "developer_extra", "0", "prints additional debugging messages, often very verbose!"};
cvar_t developer_insane = {0, "developer_insane", "0", "prints huge streams of information about internal workings, entire contents of files being read/written, etc.  Not recommended!"};
cvar_t developer_loading = {0, "developer_loading", "0", "prints information about files as they are loaded or unloaded successfully"};
// model_brush.c (not linked): the fields are set by tv_setcvar, as Cvar_RegisterVariable / Cvar_SetQuick would
cvar_t mod_noshader_default_offsetmapping = {CVAR_SAVE, "mod_noshader_default_offsetmapping", "1", ""};
cvar_t mod_q3shader_default_offsetmapping = {CVAR_SAVE, "mod_q3shader_default_offsetmapping", "1", ""};
cvar_t mod_q3shader_default_offsetmapping_scale = {CVAR_SAVE, "mod_q3shader_default_offsetmapping_scale", "1", ""};
cvar_t mod_q3shader_default_offsetmapping_bias = {CVAR_SAVE, "mod_q3shader_default_offsetmapping_bias", "0", ""};
cvar_t mod_q3shader_default_polygonfactor = {0, "mod_q3shader_default_polygonfactor", "0", ""};
cvar_t mod_q3shader_default_polygonoffset = {0, "mod_q3shader_default_polygonoffset", "-2", ""};
cvar_t mod_q3shader_force_addalpha = {0, "mod_q3shader_force_addalpha", "0", ""};
cvar_t mod_q3shader_force_terrain_alphaflag = {0, "mod_q3shader_force_terrain_alphaflag", "0", ""};

void Con_Print(const char *txt) { (void)txt; }
void Con_Printf(const char *fmt, ...) { (void)fmt; }
void Con_DPrint(const char *msg) { (void)msg; }
void Con_DPrintf(const char *fmt, ...) { (void)fmt; }

// zone.c: plain zeroed heap blocks (pools are not tracked; nothing is freed per pool)
void *_Mem_Alloc(mempool_t *pool, void *data, size_t size, size_t alignment, const char *filename, int fileline)
{
	(void)pool; (void)alignment; (void)filename; (void)fileline;
	if (data)
		return realloc(data, size + 64);
	return calloc(1, size + 64);
}
void _Mem_Free(void *data, const char *filename, int fileline)
{
	(void)filename; (void)fileline;
	free(data);
}
mempool_t *_Mem_AllocPool(const char *name, int flags, mempool_t *parent, const char *filename, int fileline)
{
	(void)name; (void)flags; (void)parent; (void)filename; (void)fileline;
	return (mempool_t *)calloc(1, sizeof(mempool_t));
}
void _Mem_FreePool(mempool_t **pool, const char *filename, int fileline)
{
	(void)filename; (void)fileline;
	if (*pool)
	{
		free(*pool);
		*pool = NULL;
	}
}
char *Mem_strdup(mempool_t *pool, const char *s)
{
	char *p;
	size_t sz;
	if (s == NULL)
		return NULL;
	sz = strlen(s) + 1;
	p = (char *)_Mem_Alloc(pool, NULL, sz, 16, __FILE__, __LINE__);
	strlcpy(p, s, sz);
	return p;
}
void Mem_ExpandableArray_NewArray(memexpandablearray_t *l, mempool_t *mempool, size_t recordsize, int numrecordsperarray)
{
	memset(l, 0, sizeof(*l));
	l->mempool = mempool;
	l->recordsize = recordsize;
	l->numrecordsperarray = numrecordsperarray;
}
void *Mem_ExpandableArray_AllocRecord(memexpandablearray_t *l)
{
	return calloc(1, l->recordsize);
}

// fs.c: the fixture directory stands for the game's virtual file system
#define TV_ROOT "tests/fixtures/shaders/"
unsigned char *FS_LoadFile(const char *path, mempool_t *pool, qboolean quiet, fs_offset_t *filesizepointer)
{
	char full[1024];
	FILE *f;
	long n;
	unsigned char *buf;
	(void)quiet;
	dpsnprintf(full, sizeof(full), "%s%s", TV_ROOT, path);
	f = fopen(full, "rb");
	if (!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	n = ftell(f);
	fseek(f, 0, SEEK_SET);
	buf = (unsigned char *)_Mem_Alloc(pool, NULL, n + 1, 16, __FILE__, __LINE__);
	if (fread(buf, 1, n, f) != (size_t)n)
		n = 0;
	fclose(f);
	buf[n] = 0;
	if (filesizepointer)
		*filesizepointer = n;
	return buf;
}
// FS_Search("scripts/*.shader"): every file of the fixture scripts/ directory whose name ends in .shader
// (case-insensitively, as the pattern match is), sorted with strcasecmp (stringlistsort), as engine/fs.luau does
static int tv_namecmp(const void *a, const void *b)
{
	const char *x = *(const char *const *)a, *y = *(const char *const *)b;
	int c = strcasecmp(x, y);
	return c ? c : strcmp(x, y);
}
fssearch_t *FS_Search(const char *pattern, int caseinsensitive, int quiet)
{
	DIR *d;
	struct dirent *e;
	fssearch_t *s;
	char **names = NULL;
	int n = 0, i;
	size_t l;
	(void)caseinsensitive; (void)quiet;
	if (strcmp(pattern, "scripts/*.shader"))
	{
		fprintf(stderr, "unexpected FS_Search pattern %s\n", pattern);
		exit(1);
	}
	d = opendir(TV_ROOT "scripts");
	if (!d)
		return NULL;
	while ((e = readdir(d)))
	{
		l = strlen(e->d_name);
		if (l > 7 && !strcasecmp(e->d_name + l - 7, ".shader"))
		{
			names = (char **)realloc(names, sizeof(char *) * (n + 1));
			names[n] = (char *)malloc(l + 9);
			dpsnprintf(names[n], l + 9, "scripts/%s", e->d_name);
			n++;
		}
	}
	closedir(d);
	if (!n)
		return NULL;
	qsort(names, n, sizeof(char *), tv_namecmp);
	s = (fssearch_t *)calloc(1, sizeof(*s));
	s->numfilenames = n;
	s->filenames = names;
	for (i = 0; i < n; i++)
		printf("F\t%d\t%s\n", i, names[i]);
	return s;
}
void FS_FreeSearch(fssearch_t *search)
{
	int i;
	for (i = 0; i < search->numfilenames; i++)
		free(search->filenames[i]);
	free(search->filenames);
	free(search);
}

// cvar.c Cvar_VariableValue: atof of the string of a cvar in this fixed table, 0 if there is none
static const char *tv_cvars[][2] = {
	{"tv_zero", "0"}, {"tv_one", "1"}, {"tv_tenth", "0.1"}, {"tv_neg", "-2.5"}, {"tv_str", "abc"},
};
float Cvar_VariableValue(const char *var_name)
{
	size_t i;
	for (i = 0; i < sizeof(tv_cvars) / sizeof(tv_cvars[0]); i++)
		if (!strcmp(tv_cvars[i][0], var_name))
			return atof(tv_cvars[i][1]);
	return 0;
}

// gl_rmain.c: what a dedicated server gets
skinframe_t *R_SkinFrame_LoadMissing(void) { return NULL; }
rtexture_t *R_GetCubemap(const char *basename) { (void)basename; return NULL; }

// ---- printing
static uint32_t tv_bits(float f)
{
	uint32_t u;
	memcpy(&u, &f, 4);
	return u;
}
static void tv_pf(float f) { printf("\t%08x", tv_bits(f)); }
static void tv_pfs(const float *f, int n)
{
	int i;
	for (i = 0; i < n; i++)
		tv_pf(f[i]);
}
static void tv_pi(int i) { printf("\t%d", i); }
static void tv_pu(unsigned int u) { printf("\t%u", u); }
static void tv_ps(const char *s)
{
	const unsigned char *c = (const unsigned char *)s;
	putchar('\t');
	for (; *c; c++)
	{
		if (*c == '\\')
			fputs("\\\\", stdout);
		else if (*c == '\t')
			fputs("\\t", stdout);
		else if (*c == '\n')
			fputs("\\n", stdout);
		else if (*c == '\r')
			fputs("\\r", stdout);
		else if (*c < 0x20 || *c >= 0x7f)
			printf("\\x%02x", *c);
		else
			putchar(*c);
	}
}
static int tv_iszero(const void *p, size_t n)
{
	const unsigned char *c = (const unsigned char *)p;
	while (n--)
		if (*c++)
			return 0;
	return 1;
}
static void tv_rgbgen(const q3shaderinfo_layer_rgbgen_t *g)
{
	tv_pi(g->rgbgen);
	tv_pfs(g->parms, Q3RGBGEN_MAXPARMS);
	tv_pi(g->wavefunc);
	tv_pfs(g->waveparms, Q3WAVEPARMS);
}
static void tv_alphagen(const q3shaderinfo_layer_alphagen_t *g)
{
	tv_pi(g->alphagen);
	tv_pfs(g->parms, Q3ALPHAGEN_MAXPARMS);
	tv_pi(g->wavefunc);
	tv_pfs(g->waveparms, Q3WAVEPARMS);
}
static void tv_tcgen(const q3shaderinfo_layer_tcgen_t *g)
{
	tv_pi(g->tcgen);
	tv_pfs(g->parms, Q3TCGEN_MAXPARMS);
}
// the 8 tcmods of a layer or pass: Z for an all-zero entry
static void tv_tcmods(const q3shaderinfo_layer_tcmod_t *m)
{
	int k;
	for (k = 0; k < Q3MAXTCMODS; k++)
	{
		if (tv_iszero(m + k, sizeof(m[k])))
		{
			printf("\tZ");
			continue;
		}
		tv_pi(m[k].tcmod);
		tv_pfs(m[k].parms, Q3TCMOD_MAXPARMS);
		tv_pi(m[k].wavefunc);
		tv_pfs(m[k].waveparms, Q3WAVEPARMS);
	}
}
static void tv_deform(const q3shaderinfo_deform_t *d)
{
	if (tv_iszero(d, sizeof(*d)))
	{
		printf("\tZ");
		return;
	}
	tv_pi(d->deform);
	tv_pfs(d->parms, Q3DEFORM_MAXPARMS);
	tv_pi(d->wavefunc);
	tv_pfs(d->waveparms, Q3WAVEPARMS);
}
static int tv_layerzero(const q3shaderinfo_layer_t *l)
{
	int k;
	if (l->alphatest || l->clampmap || tv_bits(l->framerate) || l->numframes || l->dptexflags || l->texturename || l->blendfunc[0] || l->blendfunc[1])
		return 0;
	if (!tv_iszero(&l->rgbgen, sizeof(l->rgbgen)) || !tv_iszero(&l->alphagen, sizeof(l->alphagen)) || !tv_iszero(&l->tcgen, sizeof(l->tcgen)))
		return 0;
	for (k = 0; k < Q3MAXTCMODS; k++)
		if (!tv_iszero(&l->tcmods[k], sizeof(l->tcmods[k])))
			return 0;
	return 1;
}

static void tv_shader(int bucket, const q3shaderinfo_t *s)
{
	int i, j;
	printf("S");
	tv_pi(bucket);
	tv_ps(s->name);
	tv_pu((unsigned int)s->surfaceparms);
	tv_pu((unsigned int)s->surfaceflags);
	tv_pi(s->textureflags);
	tv_pi(s->numlayers);
	tv_pi(s->lighting);
	tv_pi(s->vertexalpha);
	tv_pi(s->textureblendalpha);
	tv_ps(s->skyboxname);
	tv_pi(s->dpnortlight);
	tv_pi(s->dpshadow);
	tv_pi(s->dpnoshadow);
	tv_pi(s->dpmeshcollisions);
	tv_pi(s->dpshaderkill);
	tv_ps(s->dpreflectcube);
	tv_pf(s->reflectmin);
	tv_pf(s->reflectmax);
	tv_pf(s->refractfactor);
	tv_pfs(s->refractcolor4f, 4);
	tv_pf(s->reflectfactor);
	tv_pfs(s->reflectcolor4f, 4);
	tv_pf(s->r_water_wateralpha);
	tv_pfs(s->r_water_waterscroll, 2);
	tv_pi(s->offsetmapping);
	tv_pf(s->offsetscale);
	tv_pf(s->offsetbias);
	tv_pf(s->biaspolygonoffset);
	tv_pf(s->biaspolygonfactor);
	tv_pi(s->transparentsort);
	tv_pf(s->specularscalemod);
	tv_pf(s->specularpowermod);
	tv_pf(s->rtlightambient);
	printf("\n");
	// every layer of the struct, also past numlayers (a killed shader keeps its parsed layers)
	for (i = 0; i < Q3SHADER_MAXLAYERS; i++)
	{
		const q3shaderinfo_layer_t *l = s->layers + i;
		printf("L");
		tv_pi(i);
		if (tv_layerzero(l))
		{
			printf("\tZ\n");
			continue;
		}
		tv_pi(l->alphatest);
		tv_pi(l->clampmap);
		tv_pf(l->framerate);
		tv_pi(l->numframes);
		tv_pi(l->dptexflags);
		tv_pi(l->blendfunc[0]);
		tv_pi(l->blendfunc[1]);
		tv_rgbgen(&l->rgbgen);
		tv_alphagen(&l->alphagen);
		tv_tcgen(&l->tcgen);
		if (!l->texturename)
			printf("\t-");
		else
		{
			tv_pi(l->numframes);
			for (j = 0; j < l->numframes; j++)
				tv_ps(l->texturename[j]);
		}
		tv_tcmods(l->tcmods);
		printf("\n");
	}
	for (i = 0; i < Q3MAXDEFORMS; i++)
	{
		printf("D");
		tv_pi(i);
		tv_deform(s->deforms + i);
		printf("\n");
	}
}

static void tv_dumpshaders(void)
{
	int i, n = 0;
	q3shader_hash_entry_t *e;
	for (i = 0; i < Q3SHADER_HASH_SIZE; i++)
	{
		e = q3shader_data->hash + i;
		// an unused head entry is all zero; a used one never has an empty name (see Q3Shader_AddToHash)
		if (e->shader.name[0])
		{
			tv_shader(i, &e->shader);
			n++;
		}
		for (e = e->chain; e; e = e->chain)
		{
			tv_shader(i, &e->shader);
			n++;
		}
	}
	printf("SN\t%d\n", n);
}

// ---- textures
typedef struct tv_texcase_s
{
	const char *name; // NULL: Mod_LoadTextureFromQ3Shader(texture, NULL, ...)
	int lumpflags; // texture->surfaceflags before the call (the q3bsp texture lump)
	int texflags; // defaulttexflags
	int warnmissing, fallback;
}
tv_texcase_t;
#define TV_DEFAULT (TEXF_MIPMAP | TEXF_PICMIP | TEXF_COMPRESS | TEXF_ISWORLD)
static const tv_texcase_t tv_texcases[] = {
	{"textures/tv/first", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/closeonline", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/afterclose", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/oneline", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/lastinfirst", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/blend_short", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/blend_explicit", 0, TEXF_MIPMAP, 1, 1},
	{"textures/tv/maps", 0, TEXF_ISSPRITE, 0, 1},
	{"textures/tv/gens", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/waves", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/tcmods", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/lightmap0", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/lightmap2", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/terrain", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/terrain_at", 0, TEXF_PICMIP | TEXF_ISSPRITE, 1, 1},
	{"textures/tv/vertexlit", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/diffuse", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/effect", 0, TV_DEFAULT, 1, 1},
	{"TEXTURES/TV/EFFECT", 0, 0, 0, 0},
	{"textures/tv/chainhead211", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/sp_all", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/sp_custom", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/sp_neg", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/sp_big", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/sp_negbig", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/sp_huge", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/sp_prec", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/sp_lava", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/sp_slime", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/sp_water", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/sp_botclip", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/sp_nodraw", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/general", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/general", 128, TV_DEFAULT, 1, 1},
	{"textures/tv/water", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/refract", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/scroll", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/reflectcube_stale", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/sky", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/skyparms", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/skyparms_dash", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/skyparms_num", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/skyparms_zero", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/sky_alone", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/cull_disable", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/cull_twosided", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/cull_back", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/polyoff1", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/polyoff2", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/polyoff3", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/tsort_sky", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/tsort_distance", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/tsort_bogus", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/om_off", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/om_none", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/om_off2", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/om_default", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/om_normal", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/om_relief", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/om_bogus", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/om_four", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/deform1", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/deform2", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/deform3", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/deform4", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/kill_zero", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/kill_zero_no", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/kill_eq", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/kill_gt", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/kill_un", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/kill_alpha", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/redecl_diff", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/redecl_case", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/redecl_killed_then_normal", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/redecl_normal_then_killed", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/redecl_killed_twice", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/chain828", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/chain989", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/chain1233", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/long_0123456789012345678901234567890123456789012345678901234567890_first", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/long_0123456789012345678901234567890123456789012345", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/exact63_abcdefghijklmnopqrstuvwxyzabcdefghijklmnopq", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/quoted name", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/single \"dq\" inside", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/esc\tname\\x\"q", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/comments", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/swallow", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/swallowed_name", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/crlf", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/cr", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/punct", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/longparm", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/beforemissing", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/missing", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/aftermissing", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/nameonly", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/eofbody", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/eoflayer", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/ignored", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/unknown", 0, TV_DEFAULT, 1, 1},
	{"textures/tv/unknown", 128, TV_DEFAULT, 1, 1},
	{"textures/tv/unknown", 4, TV_DEFAULT, 0, 0},
	{"textures/tv/unknown", 132, 0, 1, 0},
	{"textures/tv/unknown", 1, TEXF_ISSPRITE, 0, 1},
	{"noshader", 0, TV_DEFAULT, 1, 1},
	{"noshader", 128, TV_DEFAULT, 1, 1},
	{"", 0, TV_DEFAULT, 1, 1},
	{NULL, 4, TV_DEFAULT, 1, 1},
	{"textures/common/nodraw", 0, TV_DEFAULT, 1, 1},
	{"common/nodraw", 4, TV_DEFAULT, 1, 1},
	{"TEXTURES/COMMON/NODRAW", 0, TV_DEFAULT, 1, 1},
};

static texture_t tv_tex;
static void tv_pass(const texture_shaderpass_t *p)
{
	int k, n = 0;
	tv_pi(p->alphatest);
	tv_pf(p->framerate);
	tv_pi(p->numframes);
	tv_pi(p->blendfunc[0]);
	tv_pi(p->blendfunc[1]);
	tv_rgbgen(&p->rgbgen);
	tv_alphagen(&p->alphagen);
	tv_tcgen(&p->tcgen);
	tv_tcmods(p->tcmods);
	for (k = 0; k < TEXTURE_MAXFRAMES; k++)
		if (p->skinframes[k])
			n++;
	tv_pi(n);
}
static int tv_passindex(const texture_t *t, const texture_shaderpass_t *p)
{
	int k;
	if (!p)
		return -1;
	for (k = 0; k < Q3SHADER_MAXLAYERS; k++)
		if (t->shaderpasses[k] == p)
			return k;
	return -2;
}
static void tv_texture(int idx, const tv_texcase_t *c)
{
	texture_t *t = &tv_tex;
	int ret, k, n;
	printf("TC");
	tv_pi(idx);
	tv_pi(c->name == NULL);
	tv_ps(c->name ? c->name : "");
	tv_pi(c->lumpflags);
	tv_pi(c->texflags);
	tv_pi(c->warnmissing);
	tv_pi(c->fallback);
	printf("\n");
	memset(t, 0, sizeof(*t));
	t->surfaceflags = c->lumpflags;
	loadmodel->brush.skybox[0] = 0;
	ret = Mod_LoadTextureFromQ3Shader(t, c->name, c->warnmissing, c->fallback, c->texflags);
	n = 0;
	for (k = 0; k < Q3SHADER_MAXLAYERS; k++)
		if (t->shaderpasses[k])
			n++;
	printf("T");
	tv_pi(idx);
	tv_pi(ret);
	tv_ps(t->name);
	tv_pf(t->basealpha);
	tv_pi(t->basematerialflags);
	tv_pu((unsigned int)t->surfaceflags);
	tv_pi(t->supercontents);
	tv_pi(t->customblendfunc[0]);
	tv_pi(t->customblendfunc[1]);
	tv_pi(t->transparentsort);
	tv_pi(t->offsetmapping);
	tv_pf(t->offsetscale);
	tv_pf(t->offsetbias);
	tv_pf(t->biaspolygonoffset);
	tv_pf(t->biaspolygonfactor);
	tv_pf(t->specularscalemod);
	tv_pf(t->specularpowermod);
	tv_pf(t->rtlightambient);
	tv_pf(t->reflectmin);
	tv_pf(t->reflectmax);
	tv_pf(t->refractfactor);
	tv_pfs(t->refractcolor4f, 4);
	tv_pf(t->reflectfactor);
	tv_pfs(t->reflectcolor4f, 4);
	tv_pf(t->r_water_wateralpha);
	tv_pfs(t->r_water_waterscroll, 2);
	tv_pi(t->startpreshaderpass);
	tv_pi(t->endpreshaderpass);
	tv_pi(t->startpostshaderpass);
	tv_pi(t->endpostshaderpass);
	tv_pi(tv_passindex(t, t->materialshaderpass));
	tv_pi(tv_passindex(t, t->backgroundshaderpass));
	tv_pi(n);
	tv_pi(t->currentframe == t);
	tv_pi(t->currentskinframe != NULL);
	tv_pi(t->backgroundcurrentskinframe != NULL);
	tv_pi(t->reflectcubetexture != NULL);
	tv_ps(loadmodel->brush.skybox);
	printf("\n");
	for (k = 0; k < Q3SHADER_MAXLAYERS; k++)
	{
		if (!t->shaderpasses[k])
			continue;
		printf("TP");
		tv_pi(idx);
		tv_pi(k);
		tv_pass(t->shaderpasses[k]);
		printf("\n");
	}
	for (k = 0; k < Q3MAXDEFORMS; k++)
	{
		printf("TD");
		tv_pi(idx);
		tv_pi(k);
		tv_deform(t->deforms + k);
		printf("\n");
	}
}

// ---- configurations
static void tv_setcvar(cvar_t *c, const char *s)
{
	// Cvar_SetQuick_Internal: value = atof(string), integer = (int)value
	c->string = s;
	c->value = atof(s);
	c->integer = (int)c->value;
	printf("\t%s\t%s", c->name, s);
}
static void tv_config(const char *tag, const char **v)
{
	printf("CFG\t%s", tag);
	tv_setcvar(&mod_q3shader_default_offsetmapping, v[0]);
	tv_setcvar(&mod_q3shader_default_offsetmapping_scale, v[1]);
	tv_setcvar(&mod_q3shader_default_offsetmapping_bias, v[2]);
	tv_setcvar(&mod_q3shader_default_polygonoffset, v[3]);
	tv_setcvar(&mod_q3shader_default_polygonfactor, v[4]);
	tv_setcvar(&mod_q3shader_force_addalpha, v[5]);
	tv_setcvar(&mod_q3shader_force_terrain_alphaflag, v[6]);
	tv_setcvar(&mod_noshader_default_offsetmapping, v[7]);
	printf("\n");
}

static dp_model_t tv_model;
int main(void)
{
	static const char *cfga[8] = {"1", "0.3", "0.1", "-2.5", "0.1", "0", "0", "1"};
	static const char *cfgb[8] = {"0", "1", "0", "-2", "0", "1", "1", "0"};
	size_t i;
	cls.state = ca_dedicated;
	loadmodel = &tv_model;
	strlcpy(tv_model.name, "tvmodel", sizeof(tv_model.name));
	for (i = 0; i < sizeof(tv_cvars) / sizeof(tv_cvars[0]); i++)
		printf("CV\t%s\t%s\n", tv_cvars[i][0], tv_cvars[i][1]);
	tv_config("A", cfga);
	Mod_LoadQ3Shaders();
	tv_dumpshaders();
	for (i = 0; i < sizeof(tv_texcases) / sizeof(tv_texcases[0]); i++)
		tv_texture((int)i, tv_texcases + i);
	tv_config("B", cfgb);
	Mod_LoadQ3Shaders();
	tv_dumpshaders();
	for (i = 0; i < sizeof(tv_texcases) / sizeof(tv_texcases[0]); i++)
		tv_texture((int)i, tv_texcases + i);
	printf("END\n");
	return 0;
}
