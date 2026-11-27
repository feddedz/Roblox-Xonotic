// Reference vectors for engine/model_alias.luau and engine/model_sprite.luau: the release's model_shared.c,
// model_alias.c and model_sprite.c are included unchanged (so their static functions and the static model
// registry can be reached) and linked with model_brush.c (Mod_MakeCollisionBIH, the BIH traces), bih.c,
// collision.c, polygon.c, mathlib.c, matrixlib.c, common.c and both skeletal vertex files
// (alias_vectors.sh). The fixture models of tests/fixtures/models/ (tools/testgen/make_model_fixtures.py) are
// loaded through the real Mod_ForName on a dedicated server, then every field the loaders set is printed, then
// Mod_Alias_GetTagMatrix / GetExtendedTagInfoForIndex / GetTagIndexForName, AnimateVertices (and the SSE version
// next to the generic one, for information) and TraceLine / TraceBox are run on a list of cases. Floats are
// printed as bit patterns, doubles as 64-bit patterns, arrays as the hex of their bytes, strings escaped
// (\\ \t \n \r \xHH). All names here start with av_ because they share a translation unit with the engine files.
#include "model_shared.c"
#include "model_alias.c"
#include "model_sprite.c"
#include "mod_skeletal_animatevertices_sse.h"
#include <stdint.h>
#include <ctype.h>

// ---- what the linked code needs from the rest of the engine
client_static_t cls;
viddef_t vid;
mempool_t *tempmempool;
mempool_t *zonemempool;
cvar_t developer_extra = {0, "developer_extra", "0", "prints additional debugging messages, often very verbose!"};
cvar_t developer_insane = {0, "developer_insane", "0", "prints huge streams of information about internal workings, entire contents of files being read/written, etc.  Not recommended!"};
cvar_t developer_loading = {0, "developer_loading", "0", "prints information about files as they are loaded or unloaded successfully"};
// renderer cvars (gl_rmain.c, gl_textures.c, gl_backend.c): not registered on a dedicated server, so they read 0
cvar_t r_smoothnormals_areaweighting = {0, "r_smoothnormals_areaweighting", "1", ""};
cvar_t r_fullbrights = {CVAR_SAVE, "r_fullbrights", "1", ""};
cvar_t gl_texturecompression = {CVAR_SAVE, "gl_texturecompression", "0", ""};
cvar_t gl_texturecompression_sprites = {CVAR_SAVE, "gl_texturecompression_sprites", "1", ""};
cvar_t gl_paranoid = {0, "gl_paranoid", "0", ""};
// model_brush.c (linked): registered here as Mod_BrushInit would
extern cvar_t mod_noshader_default_offsetmapping;
extern cvar_t mod_q3shader_default_offsetmapping;
extern cvar_t mod_q3shader_default_offsetmapping_scale;
extern cvar_t mod_q3shader_default_offsetmapping_bias;
extern cvar_t mod_q3shader_default_polygonfactor;
extern cvar_t mod_q3shader_default_polygonoffset;
extern cvar_t mod_q3shader_force_addalpha;
extern cvar_t mod_q3shader_force_terrain_alphaflag;
extern cvar_t mod_collision_bih;

void Con_Print(const char *txt) { (void)txt; }
void Con_Printf(const char *fmt, ...) { (void)fmt; }
void Con_DPrint(const char *msg) { (void)msg; }
void Con_DPrintf(const char *fmt, ...) { (void)fmt; }
void Host_Error(const char *error, ...)
{
	fprintf(stderr, "Host_Error: %s\n", error);
	exit(1);
}
void Sys_Error(const char *error, ...)
{
	fprintf(stderr, "Sys_Error: %s\n", error);
	exit(1);
}
void Host_StartVideo(void) {}
void SCR_PushLoadingScreen(qboolean redraw, const char *msg, float prog) { (void)redraw; (void)msg; (void)prog; }
void SCR_PopLoadingScreen(qboolean redraw) { (void)redraw; }
void CL_KeepaliveMessage(qboolean readmessages) { (void)readmessages; }
qboolean Sys_HaveSSE(void) { return false; } // the generic skeletal code path (the Luau port has that one)

// cvar.c Cvar_RegisterVariable: value = atof(string), integer = (int)value (what the engine code reads)
void Cvar_RegisterVariable(cvar_t *c)
{
	c->value = atof(c->string);
	c->integer = (int)c->value;
}
float Cvar_VariableValue(const char *var_name) { (void)var_name; return 0; }

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
// zone.c Mem_ExpandableArray_*: one flat array of records (same first-free order as the C arrays of 16)
#define AV_MAXRECORDS 64
static void *av_records[AV_MAXRECORDS];
static int av_used[AV_MAXRECORDS];
void Mem_ExpandableArray_NewArray(memexpandablearray_t *l, mempool_t *mempool, size_t recordsize, int numrecordsperarray)
{
	memset(l, 0, sizeof(*l));
	l->mempool = mempool;
	l->recordsize = recordsize;
	l->numrecordsperarray = numrecordsperarray;
}
void *Mem_ExpandableArray_AllocRecord(memexpandablearray_t *l)
{
	int i;
	for (i = 0; i < AV_MAXRECORDS; i++)
	{
		if (!av_used[i])
		{
			if (!av_records[i])
				av_records[i] = calloc(1, l->recordsize);
			memset(av_records[i], 0, l->recordsize);
			av_used[i] = 1;
			return av_records[i];
		}
	}
	fprintf(stderr, "out of records\n");
	exit(1);
}
void Mem_ExpandableArray_FreeRecord(memexpandablearray_t *l, void *record)
{
	int i;
	(void)l;
	for (i = 0; i < AV_MAXRECORDS; i++)
		if (av_records[i] == record)
			av_used[i] = 0;
}
size_t Mem_ExpandableArray_IndexRange(const memexpandablearray_t *l)
{
	int i, e = 0;
	(void)l;
	for (i = 0; i < AV_MAXRECORDS; i++)
		if (av_used[i])
			e = i + 1;
	return e;
}
void *Mem_ExpandableArray_RecordAtIndex(const memexpandablearray_t *l, size_t i)
{
	(void)l;
	return (i < AV_MAXRECORDS && av_used[i]) ? av_records[i] : NULL;
}

// fs.c: the fixture directory stands for the game's virtual file system
#define AV_ROOT "tests/fixtures/models/"
unsigned char *FS_LoadFile(const char *path, mempool_t *pool, qboolean quiet, fs_offset_t *filesizepointer)
{
	char full[1024];
	FILE *f;
	long n;
	unsigned char *buf;
	(void)quiet;
	dpsnprintf(full, sizeof(full), "%s%s", AV_ROOT, path);
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
fssearch_t *FS_Search(const char *pattern, int caseinsensitive, int quiet)
{
	fssearch_t *s;
	(void)caseinsensitive; (void)quiet;
	if (strcmp(pattern, "scripts/*.shader"))
	{
		fprintf(stderr, "unexpected FS_Search pattern %s\n", pattern);
		exit(1);
	}
	s = (fssearch_t *)calloc(1, sizeof(*s));
	s->numfilenames = 1;
	s->filenames = (char **)calloc(1, sizeof(char *));
	s->filenames[0] = (char *)"scripts/tvmodels.shader";
	return s;
}
void FS_FreeSearch(fssearch_t *search) { free(search->filenames); free(search); }
// fs.c FS_FileExtension, FS_StripExtension and image.c Image_StripImageExtension, copied unchanged
const char *FS_FileExtension (const char *in)
{
	const char *separator, *backslash, *colon, *dot;

	separator = strrchr(in, '/');
	backslash = strrchr(in, '\\');
	if (!separator || separator < backslash)
		separator = backslash;
	colon = strrchr(in, ':');
	if (!separator || separator < colon)
		separator = colon;

	dot = strrchr(in, '.');
	if (dot == NULL || (separator && (dot < separator)))
		return "";

	return dot + 1;
}
void FS_StripExtension (const char *in, char *out, size_t size_out)
{
	char *last = NULL;
	char currentchar;

	if (size_out == 0)
		return;

	while ((currentchar = *in) && size_out > 1)
	{
		if (currentchar == '.')
			last = out;
		else if (currentchar == '/' || currentchar == '\\' || currentchar == ':')
			last = NULL;
		*out++ = currentchar;
		in++;
		size_out--;
	}
	if (last)
		*last = 0;
	else
		*out = 0;
}
void Image_StripImageExtension (const char *in, char *out, size_t size_out)
{
	const char *ext;

	if (size_out == 0)
		return;

	ext = FS_FileExtension(in);
	if (ext && (!strcmp(ext, "tga") || !strcmp(ext, "pcx") || !strcmp(ext, "lmp") || !strcmp(ext, "png") || !strcmp(ext, "jpg") || !strcmp(ext, "wal")))
		FS_StripExtension(in, out, size_out);
	else
		strlcpy(out, in, size_out);
}

// gl_rmain.c / gl_backend.c / image.c: what a dedicated server gets
skinframe_t *R_SkinFrame_LoadMissing(void) { return NULL; }
skinframe_t *R_SkinFrame_LoadExternal(const char *name, int textureflags, qboolean complain) { (void)name; (void)textureflags; (void)complain; return NULL; }
skinframe_t *R_SkinFrame_LoadInternalQuake(const char *name, int textureflags, int loadpantsandshirt, int loadglowtexture, const unsigned char *skindata, int width, int height) { (void)name; (void)textureflags; (void)loadpantsandshirt; (void)loadglowtexture; (void)skindata; (void)width; (void)height; return NULL; }
skinframe_t *R_SkinFrame_LoadInternalBGRA(const char *name, int textureflags, const unsigned char *skindata, int width, int height, qboolean sRGB) { (void)name; (void)textureflags; (void)skindata; (void)width; (void)height; (void)sRGB; return NULL; }
rtexture_t *R_GetCubemap(const char *basename) { (void)basename; return NULL; }
r_meshbuffer_t *R_Mesh_CreateMeshBuffer(const void *data, size_t size, const char *name, qboolean isindexbuffer, qboolean isuniformbuffer, qboolean isdynamic, qboolean isindex16) { (void)data; (void)size; (void)name; (void)isindexbuffer; (void)isuniformbuffer; (void)isdynamic; (void)isindex16; return NULL; }

// ---- printing
static uint32_t av_bits(float f)
{
	uint32_t u;
	memcpy(&u, &f, 4);
	return u;
}
static unsigned long long av_dbits(double d)
{
	unsigned long long u;
	memcpy(&u, &d, 8);
	return u;
}
static void av_pf(float f) { printf("\t%08x", av_bits(f)); }
static void av_pv(const float *v) { av_pf(v[0]); av_pf(v[1]); av_pf(v[2]); }
static void av_pi(int i) { printf("\t%d", i); }
static void av_ps(const char *s)
{
	const unsigned char *c = (const unsigned char *)s;
	putchar('\t');
	if (!s)
	{
		fputs("(null)", stdout);
		return;
	}
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
// a name field of a fixed-size char array, as C code reads it (strlen bounded by the field)
static void av_pname(const char *s, size_t size)
{
	char tmp[256];
	size_t n = strnlen(s, size);
	memcpy(tmp, s, n);
	tmp[n] = 0;
	av_ps(tmp);
}
static void av_array(const char *name, const void *p, size_t n)
{
	size_t i;
	const unsigned char *c = (const unsigned char *)p;
	printf("A\t%s", name);
	if (!p)
	{
		printf("\t-\n");
		return;
	}
	printf("\t%u\t", (unsigned int)n);
	for (i = 0; i < n; i++)
		printf("%02x", c[i]);
	printf("\n");
}
static void av_matrix(const matrix4x4_t *m)
{
	int r, c;
	for (r = 0; r < 3; r++)
		for (c = 0; c < 4; c++)
			av_pf(m->m[r][c]);
}

static int av_traceboxkind(dp_model_t *m)
{
	if (!m->TraceBox) return 0;
	if (m->TraceBox == Mod_CollisionBIH_TraceBox) return 1;
	if (m->TraceBox == Mod_MDLMD2MD3_TraceBox) return 2;
	return 9;
}
static int av_tracelinekind(dp_model_t *m)
{
	if (!m->TraceLine) return 0;
	if (m->TraceLine == Mod_CollisionBIH_TraceLine) return 1;
	if (m->TraceLine == Mod_MDLMD2MD3_TraceLine) return 2;
	return 9;
}
static int av_animkind(dp_model_t *m)
{
	if (!m->AnimateVertices) return 0;
	if (m->AnimateVertices == Mod_Skeletal_AnimateVertices) return 1;
	if (m->AnimateVertices == Mod_MD3_AnimateVertices) return 2;
	if (m->AnimateVertices == Mod_MDL_AnimateVertices) return 3;
	return 9;
}
static int av_texindex(const dp_model_t *m, const texture_t *t)
{
	return t ? (int)(t - m->data_textures) : -1;
}

static void av_scene(const char *tag, int i, const animscene_t *s)
{
	printf("%s", tag);
	av_pi(i);
	av_pname(s->name, sizeof(s->name));
	av_pi(s->firstframe);
	av_pi(s->framecount);
	av_pi(s->loop);
	av_pf(s->framerate);
	printf("\n");
}

static void av_model(dp_model_t *m)
{
	int i, k;
	surfmesh_t *sm = &m->surfmesh;
	printf("F\tmodeldatatypestring");
	av_ps(m->modeldatatypestring);
	printf("\nF\tints");
	av_pi(m->type);
	av_pi(m->numframes);
	av_pi(m->numskins);
	av_pi(m->num_poses);
	av_pi(m->num_bones);
	av_pi(m->num_tags);
	av_pi(m->num_tagframes);
	av_pi(m->num_surfaces);
	av_pi(m->nummodelsurfaces);
	av_pi(m->num_textures);
	av_pi(m->num_texturesperskin);
	av_pi(m->synctype);
	av_pi(m->effects);
	av_pi(sm->num_vertices);
	av_pi(sm->num_triangles);
	av_pi(sm->num_blends);
	av_pi(sm->num_morphframes);
	av_pi(sm->isanimated);
	printf("\nF\tfuncs");
	av_pi(m->DrawSky != NULL);
	av_pi(m->DrawAddWaterPlanes != NULL);
	av_pi(av_traceboxkind(m));
	av_pi(av_tracelinekind(m));
	av_pi(m->TraceBrush != NULL);
	av_pi(m->TracePoint != NULL);
	av_pi(m->PointSuperContents != NULL);
	av_pi(av_animkind(m));
	printf("\nF\tfloats");
	av_pf(m->num_posescale);
	av_pf(m->num_poseinvscale);
	av_pv(m->normalmins);
	av_pv(m->normalmaxs);
	av_pv(m->yawmins);
	av_pv(m->yawmaxs);
	av_pv(m->rotatedmins);
	av_pv(m->rotatedmaxs);
	av_pf(m->radius);
	av_pf(m->radius2);
	printf("\nF\tbih");
	av_pi(m->collision_bih.numleafs);
	av_pi(m->collision_bih.numnodes);
	if (m->collision_bih.numleafs)
	{
		av_pi(m->collision_bih.rootnode);
		av_pv(m->collision_bih.mins);
		av_pv(m->collision_bih.maxs);
	}
	printf("\n");
	if (m->type == mod_sprite)
	{
		printf("F\tsprite");
		av_pi(m->sprite.sprnum_type);
		printf("\n");
		for (i = 0; i < m->num_textures; i++)
		{
			printf("SPRF");
			av_pi(i);
			av_pf(m->sprite.sprdata_frames[i].left);
			av_pf(m->sprite.sprdata_frames[i].right);
			av_pf(m->sprite.sprdata_frames[i].up);
			av_pf(m->sprite.sprdata_frames[i].down);
			printf("\n");
		}
	}
	for (i = 0; i < m->numframes; i++)
		av_scene("SC", i, m->animscenes + i);
	if (m->skinscenes)
		for (i = 0; i < m->numskins; i++)
			av_scene("SK", i, m->skinscenes + i);
	for (i = 0; i < m->num_bones; i++)
	{
		printf("BONE");
		av_pi(i);
		av_pname(m->data_bones[i].name, sizeof(m->data_bones[i].name));
		av_pi(m->data_bones[i].flags);
		av_pi(m->data_bones[i].parent);
		printf("\n");
	}
	for (i = 0; i < m->num_tags * m->num_tagframes; i++)
	{
		printf("TAG");
		av_pi(i);
		av_pname(m->data_tags[i].name, sizeof(m->data_tags[i].name));
		for (k = 0; k < 12; k++)
			av_pf(m->data_tags[i].matrixgl[k]);
		printf("\n");
	}
	for (i = 0; i < m->num_surfaces; i++)
	{
		msurface_t *s = m->data_surfaces + i;
		printf("SURF");
		av_pi(i);
		av_pi(av_texindex(m, s->texture));
		av_pi(s->num_firsttriangle);
		av_pi(s->num_triangles);
		av_pi(s->num_firstvertex);
		av_pi(s->num_vertices);
		av_pi(m->sortedmodelsurfaces[i]);
		printf("\n");
	}
	for (i = 0; i < m->num_textures; i++)
	{
		texture_t *t = m->data_textures + i;
		printf("TEX");
		av_pi(i);
		av_ps(t->name);
		av_pi(t->basematerialflags);
		av_pi(t->currentmaterialflags);
		av_pi(t->supercontents);
		av_pi(t->surfaceflags);
		av_pi(t->offsetmapping);
		av_pf(t->offsetscale);
		av_pf(t->specularscalemod);
		av_pf(t->basealpha);
		av_pi(t->transparentsort);
		av_pi(t->materialshaderpass != NULL);
		av_pi(t->currentframe == t);
		printf("\n");
	}
	av_array("element3i", sm->data_element3i, sm->num_triangles * 12);
	av_array("element3s", sm->data_element3s, sm->num_triangles * 6);
	av_array("neighbor3i", sm->data_neighbor3i, sm->num_triangles * 12);
	av_array("vertex3f", sm->data_vertex3f, sm->num_vertices * 12);
	av_array("svector3f", sm->data_svector3f, sm->num_vertices * 12);
	av_array("tvector3f", sm->data_tvector3f, sm->num_vertices * 12);
	av_array("normal3f", sm->data_normal3f, sm->num_vertices * 12);
	av_array("texcoordtexture2f", sm->data_texcoordtexture2f, sm->num_vertices * 8);
	av_array("lightmapcolor4f", sm->data_lightmapcolor4f, sm->num_vertices * 16);
	av_array("skeletalindex4ub", sm->data_skeletalindex4ub, sm->num_vertices * 4);
	av_array("skeletalweight4ub", sm->data_skeletalweight4ub, sm->num_vertices * 4);
	av_array("blends", sm->blends, sm->num_vertices * 2);
	av_array("blendweights", sm->num_blends ? (const void *)sm->data_blendweights : NULL, sm->num_blends * 8);
	av_array("poses7s", m->data_poses7s, m->num_poses * m->num_bones * 14);
	av_array("baseboneposeinverse", m->data_baseboneposeinverse, m->num_bones * 48);
	av_array("morphmd3vertex", sm->data_morphmd3vertex, sm->num_vertices * sm->num_morphframes * 8);
	av_array("morphmdlvertex", sm->data_morphmdlvertex, sm->num_vertices * sm->num_morphframes * 4);
	av_array("morphtexvecvertex", sm->data_morphtexvecvertex, sm->num_vertices * sm->num_morphframes * 6);
	av_array("morphmd2framesize6f", sm->data_morphmd2framesize6f, m->numframes * 24);
	printf("F\tmorphmdl");
	av_pv(sm->num_morphmdlframescale);
	av_pv(sm->num_morphmdlframetranslate);
	printf("\n");
}

// ---- frame blends: subframe / lerp pairs (subframes are taken modulo num_poses)
#define AV_NFB 6
static const int av_fbsub[AV_NFB][3] = {{0, 0, 0}, {1, 0, 0}, {0, 2, 0}, {1, 2, 3}, {3, 0, 0}, {2, 1, 0}};
static const float av_fblerp[AV_NFB][3] = {{1, 0, 0}, {1, 0, 0}, {0.25f, 0.75f, 0}, {0.5f, 0.3f, 0.2f}, {0.7f, 0, 0}, {0.6f, 0.6f, 0}};
static void av_makefb(const dp_model_t *m, int c, frameblend_t *fb)
{
	int k, n = m->num_poses > 0 ? m->num_poses : 1;
	memset(fb, 0, sizeof(frameblend_t) * MAX_FRAMEBLENDS);
	for (k = 0; k < 3; k++)
	{
		fb[k].subframe = av_fbsub[c][k] % n;
		fb[k].lerp = av_fblerp[c][k];
	}
}

static void av_tags(dp_model_t *m)
{
	int c, i, n, ret, parent;
	const char *tagname;
	matrix4x4_t mat;
	frameblend_t fb[MAX_FRAMEBLENDS];
	skeleton_t skel;
	matrix4x4_t rel[8];
	n = m->num_bones ? m->num_bones : m->num_tags;
	for (c = 0; c < AV_NFB; c++)
	{
		av_makefb(m, c, fb);
		for (i = -1; i <= n; i++)
		{
			memset(&mat, 0, sizeof(mat));
			ret = Mod_Alias_GetTagMatrix(m, fb, NULL, i, &mat);
			printf("TAGM");
			av_pi(c);
			av_pi(i);
			av_pi(ret);
			av_matrix(&mat);
			printf("\n");
			memset(&mat, 0, sizeof(mat));
			parent = -99;
			tagname = "-";
			ret = Mod_Alias_GetExtendedTagInfoForIndex(m, 0, fb, NULL, i, &parent, &tagname, &mat);
			printf("TAGX");
			av_pi(c);
			av_pi(i);
			av_pi(ret);
			av_pi(parent);
			av_ps(tagname);
			av_matrix(&mat);
			printf("\n");
		}
	}
	// a skeleton: relative transforms from the bone poses of frame 1, translated a little
	if (m->num_bones && m->num_bones <= 8)
	{
		for (i = 0; i < m->num_bones; i++)
		{
			Matrix4x4_FromBonePose7s(rel + i, m->num_posescale, m->data_poses7s + 7 * (((1 % m->num_poses) * m->num_bones) + i));
			rel[i].m[0][3] += 0.125f * i;
		}
		skel.model = m;
		skel.relativetransforms = rel;
		for (i = -1; i <= n; i++)
		{
			ret = Mod_Alias_GetTagMatrix(m, NULL, &skel, i, &mat);
			printf("TAGS");
			av_pi(i);
			av_pi(ret);
			av_matrix(&mat);
			printf("\n");
		}
	}
	for (i = 0; i < m->num_bones; i++)
	{
		char up[64];
		size_t k;
		printf("TAGN");
		av_pi(i);
		av_pi(Mod_Alias_GetTagIndexForName(m, 0, m->data_bones[i].name));
		strlcpy(up, m->data_bones[i].name, sizeof(up));
		for (k = 0; up[k]; k++)
			up[k] = toupper(up[k]);
		av_pi(Mod_Alias_GetTagIndexForName(m, 7, up));
		printf("\n");
	}
	for (i = 0; i < m->num_tags; i++)
	{
		printf("TAGN");
		av_pi(i);
		av_pi(Mod_Alias_GetTagIndexForName(m, 0, m->data_tags[i].name));
		av_pi(Mod_Alias_GetTagIndexForName(m, 1, "TAG_HEAD"));
		printf("\n");
	}
	printf("TAGN\t-1");
	av_pi(Mod_Alias_GetTagIndexForName(m, 0, "nonexistent"));
	printf("\n");
}

static void av_anim(dp_model_t *m)
{
	int c, mode, n = m->surfmesh.num_vertices;
	frameblend_t fb[MAX_FRAMEBLENDS];
	size_t sz = (n + 4) * sizeof(float[3]);
	float *v = (float *)calloc(1, sz), *nn = (float *)calloc(1, sz), *s = (float *)calloc(1, sz), *t = (float *)calloc(1, sz);
	float *v2 = (float *)calloc(1, sz), *nn2 = (float *)calloc(1, sz), *s2 = (float *)calloc(1, sz), *t2 = (float *)calloc(1, sz);
	if (!m->AnimateVertices || !n)
		return;
	for (c = 0; c < AV_NFB; c++)
	{
		av_makefb(m, c, fb);
		for (mode = 0; mode < 3; mode++)
		{
			memset(v, 0, sz); memset(nn, 0, sz); memset(s, 0, sz); memset(t, 0, sz);
			// mode 0: all four arrays; 1: vertices only; 2: normals and texture vectors without vertices
			m->AnimateVertices(m, fb, NULL, mode != 2 ? v : NULL, mode != 1 ? nn : NULL, mode != 1 ? s : NULL, mode != 1 ? t : NULL);
			printf("ANIM");
			av_pi(c);
			av_pi(mode);
			printf("\n");
			if (mode != 2) av_array("v", v, n * 12);
			if (mode != 1) { av_array("n", nn, n * 12); av_array("s", s, n * 12); av_array("t", t, n * 12); }
			if (m->AnimateVertices == Mod_Skeletal_AnimateVertices && m->num_bones && mode == 0)
			{
				// for information: the SSE code path of the release build on the same input
				memset(v2, 0, sz); memset(nn2, 0, sz); memset(s2, 0, sz); memset(t2, 0, sz);
				Mod_Skeletal_AnimateVertices_SSE(m, fb, NULL, v2, nn2, s2, t2);
				printf("SSE");
				av_pi(c);
				av_pi(memcmp(v, v2, n * 12) != 0);
				av_pi(memcmp(nn, nn2, n * 12) != 0);
				av_pi(memcmp(s, s2, n * 12) != 0);
				av_pi(memcmp(t, t2, n * 12) != 0);
				printf("\n");
			}
		}
	}
}

static void av_trace(dp_model_t *m)
{
	static const float starts[4][3] = {{-40, 1.5f, 2.25f}, {0.5f, -50, 0.75f}, {3, 4, 60}, {-30, -30, -30}};
	static const float ends[4][3] = {{40, -1.25f, 1.75f}, {-0.25f, 50, -0.5f}, {-2, -3, -60}, {30, 30, 30}};
	static const float mins[3][3] = {{0, 0, 0}, {-2, -2, -3}, {1, 1, 1}};
	static const float maxs[3][3] = {{0, 0, 0}, {2, 2, 4}, {1, 1, 1}};
	int c, k, b;
	frameblend_t fb[MAX_FRAMEBLENDS];
	trace_t tr;
	if (!m->TraceBox || !m->TraceLine)
		return;
	for (c = 0; c < 3; c++)
	{
		av_makefb(m, c == 2 ? 3 : c, fb);
		for (k = 0; k < 4; k++)
		{
			for (b = -1; b < 3; b++)
			{
				memset(&tr, 0, sizeof(tr));
				if (b < 0)
					m->TraceLine(m, c ? fb : NULL, NULL, &tr, starts[k], ends[k], SUPERCONTENTS_SOLID, 0, 0);
				else
					m->TraceBox(m, c ? fb : NULL, NULL, &tr, starts[k], mins[b], maxs[b], ends[k], SUPERCONTENTS_SOLID | SUPERCONTENTS_OPAQUE, 0, 0);
				printf("TR");
				av_pi(c);
				av_pi(k);
				av_pi(b);
				av_pi(tr.allsolid);
				av_pi(tr.startsolid);
				printf("\t%016llx\t%016llx\t%016llx\t%016llx", av_dbits(tr.fraction), av_dbits(tr.endpos[0]), av_dbits(tr.endpos[1]), av_dbits(tr.endpos[2]));
				av_pv(tr.plane.normal);
				av_pf(tr.plane.dist);
				av_pi(tr.hitsupercontents);
				av_pi(tr.hitq3surfaceflags);
				av_pi(av_texindex(m, tr.hittexture));
				av_pi(tr.startsupercontents);
				printf("\n");
			}
		}
	}
}

static const char *av_models[] = {
	"models/tv/a.iqm", "models/tv/b.iqm", "models/tv/c.md3", "models/tv/d.dpm", "models/tv/e.mdl", "models/tv/f.spr",
};

int main(void)
{
	size_t i;
	cls.state = ca_dedicated;
	// the cvars of the dedicated init path (Mod_Init, Mod_BrushInit, Mod_AliasInit, Mod_SpriteInit, Collision_Init)
	Cvar_RegisterVariable(&r_enableshadowvolumes);
	Cvar_RegisterVariable(&r_mipskins);
	Cvar_RegisterVariable(&r_mipnormalmaps);
	Cvar_RegisterVariable(&mod_noshader_default_offsetmapping);
	Cvar_RegisterVariable(&mod_q3shader_default_offsetmapping);
	Cvar_RegisterVariable(&mod_q3shader_default_offsetmapping_scale);
	Cvar_RegisterVariable(&mod_q3shader_default_offsetmapping_bias);
	Cvar_RegisterVariable(&mod_q3shader_default_polygonfactor);
	Cvar_RegisterVariable(&mod_q3shader_default_polygonoffset);
	Cvar_RegisterVariable(&mod_q3shader_force_addalpha);
	Cvar_RegisterVariable(&mod_q3shader_force_terrain_alphaflag);
	Cvar_RegisterVariable(&mod_collision_bih);
	Collision_Init();
	Mem_ExpandableArray_NewArray(&models, NULL, sizeof(dp_model_t), 16);
	Mod_AliasInit();
	Mod_SpriteInit();
	for (i = 0; i < sizeof(av_models) / sizeof(av_models[0]); i++)
	{
		dp_model_t *m = Mod_ForName(av_models[i], true, false, NULL);
		printf("MODEL\t%s\n", av_models[i]);
		av_model(m);
		av_tags(m);
		av_anim(m);
		av_trace(m);
	}
	printf("END\n");
	return 0;
}
