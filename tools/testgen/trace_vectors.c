// Reference vectors for the trace code of engine/collision.luau and engine/model_brush.luau: the release's
// model_brush.c is included unchanged (so its static Mod_Q3BSP_Trace* functions can be called) and linked with
// collision.c, polygon.c, bih.c and mathlib.c (trace_vectors.sh; unused functions are dropped by
// --gc-sections). A small synthetic map is built here: collision brushes, four patch-like surfaces, a BSP tree
// and a submodel. Every input the Luau test needs is printed to tests/vectors/trace.tsv next to the results;
// floats are printed as bit patterns, doubles as 64-bit patterns. All names here start with tv_ because they
// share a translation unit with model_brush.c.
#include "model_brush.c"
#include "collision.h"
#include <stdint.h>

// ---- what the linked code needs from the rest of the engine
dp_model_t *loadmodel;
cvar_t developer_extra = {0, "developer_extra", "0", "prints additional debugging messages"};
extern cvar_t collision_debug_tracelineasbox;
extern cvar_t collision_triangle_bevelsides;
extern cvar_t collision_triangle_axialsides;
void Con_Print(const char *txt) { (void)txt; }
void Con_Printf(const char *fmt, ...) { (void)fmt; }
void Con_DPrint(const char *msg) { (void)msg; }
void Con_DPrintf(const char *fmt, ...) { (void)fmt; }
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

// ---- helpers
static uint32_t tv_seed;
static uint32_t tv_rnd(void)
{
	tv_seed = tv_seed * 1664525u + 1013904223u;
	return tv_seed >> 8;
}
static float tv_frand(float lo, float hi) // multiples of 1/1024 of the range: plenty of float rounding downstream
{
	return lo + (hi - lo) * ((float)(int)(tv_rnd() % 1024) / 1024.0f);
}
static uint32_t tv_bits(float f)
{
	uint32_t u;
	memcpy(&u, &f, 4);
	return u;
}
static unsigned long long tv_dbits(double d)
{
	unsigned long long u;
	memcpy(&u, &d, 8);
	return u;
}
static void tv_pf(float f)
{
	printf("\t%08x", tv_bits(f));
}
static void tv_pv(const float *v)
{
	tv_pf(v[0]);
	tv_pf(v[1]);
	tv_pf(v[2]);
}
static void tv_randnormal(float *n)
{
	float len;
	do
	{
		n[0] = tv_frand(-1, 1);
		n[1] = tv_frand(-1, 1);
		n[2] = tv_frand(-1, 1);
		len = (float)sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
	}
	while (len < 0.2f);
	n[0] /= len;
	n[1] /= len;
	n[2] /= len;
}
#define TV_SETCV(v, n) do { (v).integer = (n); (v).value = (float)(n); printf("CVAR\t%s\t%d\n", (v).name, (int)(n)); } while (0)

// ---- textures
#define TV_NTEX 6
static texture_t tv_tex[TV_NTEX];
static int tv_texidx(const texture_t *t)
{
	return t ? (int)(t - tv_tex) : -1;
}
static void tv_maketextures(void)
{
	static const int sc[TV_NTEX] = {1, 1, 2, 0x1001, 0x100, 1};
	static const int sf[TV_NTEX] = {0, 0x20, 0, 0x4, 0, 0x8};
	static const int cmf[TV_NTEX] = {0, 0, 0x10, 0, 0, 1};
	static const int bmf[TV_NTEX] = {0, 0, 0x10, 0, 0, 1}; // texture 5: MATERIALFLAG_MESHCOLLISIONS
	int i;
	for (i = 0; i < TV_NTEX; i++)
	{
		tv_tex[i].supercontents = sc[i];
		tv_tex[i].surfaceflags = sf[i];
		tv_tex[i].currentmaterialflags = cmf[i];
		tv_tex[i].basematerialflags = bmf[i];
		printf("TEX\t%d\t%d\t%d\t%d\t%d\n", i, sc[i], sf[i], cmf[i], bmf[i]);
	}
}

static void tv_state(const char *tag, int k, const trace_t *t)
{
	printf("%s\t%d\t%d\t%d\t%016llx", tag, k, t->allsolid, t->startsolid, tv_dbits(t->fraction));
	tv_pv(t->plane.normal);
	tv_pf(t->plane.dist);
	printf("\t%d\t%d\t%d\t%d\t%016llx\t%016llx\t%016llx\t%016llx\t%d\n", t->hitsupercontents, t->hitq3surfaceflags,
		tv_texidx(t->hittexture), t->startsupercontents, tv_dbits(t->startdepth), tv_dbits(t->startdepthnormal[0]),
		tv_dbits(t->startdepthnormal[1]), tv_dbits(t->startdepthnormal[2]), tv_texidx(t->starttexture));
}
static void tv_tinit(trace_t *t, int hit, int skip, int mat)
{
	memset(t, 0, sizeof(*t));
	t->fraction = 1;
	t->hitsupercontentsmask = hit;
	t->skipsupercontentsmask = skip;
	t->skipmaterialflagsmask = mat;
}
static void tv_masks(int *hit, int *skip, int *mat)
{
	static const int hits[5] = {1, 0x101, 2, 0x1001, 3};
	static const int skips[5] = {0, 0, 0, 0x100, 2};
	static const int mats[5] = {0, 0, 0, 0x10, 1};
	*hit = hits[tv_rnd() % 5];
	*skip = skips[tv_rnd() % 5];
	*mat = mats[tv_rnd() % 5];
}

// ---- brushes
#define TV_NB 70
#define TV_NWORLDB 60
static q3mbrush_t tv_brush[TV_NB];
static float tv_bcenter[TV_NB][3];

static void tv_setplane(colplanef_t *p, float nx, float ny, float nz, float dist)
{
	p->normal[0] = nx;
	p->normal[1] = ny;
	p->normal[2] = nz;
	p->dist = dist;
	p->texture = tv_tex + (tv_rnd() % 5);
	p->q3surfaceflags = p->texture->surfaceflags;
}
// the six axial planes in the order q3map2 writes them (+x -x +y -y +z -z)
static int tv_box(colplanef_t *p, const float *mins, const float *maxs)
{
	tv_setplane(p + 0, 1, 0, 0, maxs[0]);
	tv_setplane(p + 1, -1, 0, 0, -mins[0]);
	tv_setplane(p + 2, 0, 1, 0, maxs[1]);
	tv_setplane(p + 3, 0, -1, 0, -mins[1]);
	tv_setplane(p + 4, 0, 0, 1, maxs[2]);
	tv_setplane(p + 5, 0, 0, -1, -mins[2]);
	return 6;
}
static void tv_makebrushes(void)
{
	static colplanef_t planes[64];
	int i, j, n, hasaabb, extra;
	float c[3], mins[3], maxs[3], nrm[3];
	texture_t *t;
	for (i = 0; i < TV_NB; i++)
	{
		for (j = 0; j < 3; j++)
			c[j] = i < TV_NWORLDB ? tv_frand(-480, 480) : (j == 0 ? 800.0f : 0.0f) + tv_frand(-110, 110);
		hasaabb = 1;
		if (i == 7)
		{
			// degenerate (three planes): Collision_NewBrushFromPlanes returns NULL
			tv_setplane(planes + 0, 1, 0, 0, c[0]);
			tv_setplane(planes + 1, 0, 1, 0, c[1]);
			tv_setplane(planes + 2, 0, 0, 1, c[2]);
			n = 3;
		}
		else if (i >= 50 && i < TV_NWORLDB)
		{
			// convex polytope from random planes only, no axial planes first
			hasaabb = 0;
			n = 6 + (int)(tv_rnd() % 9);
			for (j = 0; j < n; j++)
			{
				tv_randnormal(nrm);
				tv_setplane(planes + j, nrm[0], nrm[1], nrm[2], nrm[0] * c[0] + nrm[1] * c[1] + nrm[2] * c[2] + tv_frand(12, 90));
			}
		}
		else
		{
			for (j = 0; j < 3; j++)
			{
				mins[j] = c[j] - tv_frand(8, 110);
				maxs[j] = c[j] + tv_frand(8, 110);
			}
			n = tv_box(planes, mins, maxs);
			if (i % 3)
			{
				extra = 1 + (int)(tv_rnd() % 6);
				for (j = 0; j < extra; j++)
				{
					tv_randnormal(nrm);
					tv_setplane(planes + n, nrm[0], nrm[1], nrm[2], nrm[0] * c[0] + nrm[1] * c[1] + nrm[2] * c[2] + tv_frand(4, 100));
					n++;
				}
			}
		}
		t = tv_tex + (tv_rnd() % 5);
		VectorCopy(c, tv_bcenter[i]);
		tv_brush[i].texture = t;
		tv_brush[i].colbrushf = Collision_NewBrushFromPlanes(NULL, n, planes, t->supercontents, t->surfaceflags, t, hasaabb);
		printf("B\t%d\t%d\t%d\t%d\n", i, n, tv_texidx(t), hasaabb);
		for (j = 0; j < n; j++)
		{
			printf("P");
			tv_pv(planes[j].normal);
			tv_pf(planes[j].dist);
			printf("\t%d\n", tv_texidx(planes[j].texture));
		}
		printf("BR\t%d\n", tv_brush[i].colbrushf != NULL);
	}
}
static int tv_pickbrush(int m) // a brush of model m that exists
{
	int b;
	do
		b = m ? TV_NWORLDB + (int)(tv_rnd() % (TV_NB - TV_NWORLDB)) : (int)(tv_rnd() % TV_NWORLDB);
	while (!tv_brush[b].colbrushf);
	return b;
}

// ---- surfaces: height field grids, like tessellated patches
#define TV_NS 4
#define TV_NWORLDS 3
#define TV_GW 9
#define TV_GH 7
#define TV_SV (TV_GW * TV_GH)
#define TV_ST ((TV_GW - 1) * (TV_GH - 1) * 2)
static msurface_t tv_surf[TV_NS];
static float tv_cvert[TV_NS * TV_SV * 3], tv_rvert[TV_NS * TV_SV * 3], tv_lvert[TV_NS][TV_SV * 3];
static int tv_celem[TV_NS * TV_ST * 3], tv_relem[TV_NS * TV_ST * 3], tv_lelem[TV_NS][TV_ST * 3];
static float tv_bbox[TV_NS][TV_ST * 6];
static float tv_scenter[TV_NS][3];
static const int tv_stride[TV_NS] = {16, 0, -1, 4};
static const int tv_stex[TV_NS] = {0, 2, 5, 1};

static void tv_makesurfaces(void)
{
	int s, gx, gy, v, i, j, k, tri, groups;
	float o[3], stepx, stepy, *p;
	msurface_t *surf;
	for (s = 0; s < TV_NS; s++)
	{
		surf = tv_surf + s;
		if (s < TV_NWORLDS)
		{
			o[0] = tv_frand(-350, 250);
			o[1] = tv_frand(-350, 250);
			o[2] = tv_frand(-350, 250);
		}
		else
		{
			o[0] = 720;
			o[1] = -100;
			o[2] = 40;
		}
		stepx = tv_frand(14, 36);
		stepy = tv_frand(14, 36);
		for (gy = 0; gy < TV_GH; gy++)
		{
			for (gx = 0; gx < TV_GW; gx++)
			{
				v = gy * TV_GW + gx;
				p = tv_lvert[s] + v * 3;
				p[0] = o[0] + gx * stepx;
				p[1] = o[1] + gy * stepy;
				p[2] = o[2] + tv_frand(-28, 28);
				if (s == 1 && gx == 4) // a column of zero-area triangles
					VectorCopy(p - 3, p);
			}
		}
		tv_scenter[s][0] = o[0] + 4 * stepx;
		tv_scenter[s][1] = o[1] + 3 * stepy;
		tv_scenter[s][2] = o[2];
		tri = 0;
		for (gy = 0; gy < TV_GH - 1; gy++)
		{
			for (gx = 0; gx < TV_GW - 1; gx++)
			{
				int *e = tv_lelem[s] + tri * 3;
				v = gy * TV_GW + gx;
				e[0] = v;
				e[1] = v + TV_GW;
				e[2] = v + 1;
				e[3] = v + 1;
				e[4] = v + TV_GW;
				e[5] = v + TV_GW + 1;
				if (s & 1) // the other winding
				{
					e[1] = v + 1;
					e[2] = v + TV_GW;
					e[4] = v + TV_GW + 1;
					e[5] = v + TV_GW;
				}
				tri += 2;
			}
		}
		for (v = 0; v < TV_SV; v++)
		{
			VectorCopy(tv_lvert[s] + v * 3, tv_cvert + (s * TV_SV + v) * 3);
			tv_rvert[(s * TV_SV + v) * 3 + 0] = tv_lvert[s][v * 3 + 0] + 1.5f;
			tv_rvert[(s * TV_SV + v) * 3 + 1] = tv_lvert[s][v * 3 + 1];
			tv_rvert[(s * TV_SV + v) * 3 + 2] = tv_lvert[s][v * 3 + 2] + 3.0f;
		}
		for (i = 0; i < TV_ST * 3; i++)
		{
			tv_celem[s * TV_ST * 3 + i] = tv_lelem[s][i] + s * TV_SV;
			tv_relem[s * TV_ST * 3 + i] = tv_lelem[s][i] + s * TV_SV;
		}
		memset(surf, 0, sizeof(*surf));
		surf->texture = tv_tex + tv_stex[s];
		surf->num_collisiontriangles = TV_ST;
		surf->num_collisionvertices = TV_SV;
		surf->num_firstcollisiontriangle = s * TV_ST;
		surf->deprecatedq3data_collisionelement3i = tv_lelem[s];
		surf->deprecatedq3data_collisionvertex3f = tv_lvert[s];
		surf->deprecatedq3num_collisionbboxstride = tv_stride[s];
		surf->num_triangles = TV_ST;
		surf->num_firsttriangle = s * TV_ST;
		surf->num_vertices = TV_SV;
		surf->num_firstvertex = s * TV_SV;
		VectorCopy(tv_lvert[s], surf->mins);
		VectorCopy(tv_lvert[s], surf->maxs);
		for (v = 0; v < TV_SV; v++)
		{
			for (j = 0; j < 3; j++)
			{
				surf->mins[j] = min(surf->mins[j], min(tv_lvert[s][v * 3 + j], tv_rvert[(s * TV_SV + v) * 3 + j]));
				surf->maxs[j] = max(surf->maxs[j], max(tv_lvert[s][v * 3 + j], tv_rvert[(s * TV_SV + v) * 3 + j]));
			}
		}
		groups = 0;
		if (tv_stride[s] > 0)
		{
			groups = (TV_ST + tv_stride[s] - 1) / tv_stride[s];
			for (i = 0; i < groups; i++)
			{
				float *bb = tv_bbox[s] + i * 6;
				for (k = 0; k < tv_stride[s] && i * tv_stride[s] + k < TV_ST; k++)
				{
					for (j = 0; j < 3; j++)
					{
						p = tv_lvert[s] + tv_lelem[s][(i * tv_stride[s] + k) * 3 + j] * 3;
						if (k == 0 && j == 0)
						{
							VectorCopy(p, bb);
							VectorCopy(p, bb + 3);
						}
						bb[0] = min(bb[0], p[0]);
						bb[1] = min(bb[1], p[1]);
						bb[2] = min(bb[2], p[2]);
						bb[3] = max(bb[3], p[0]);
						bb[4] = max(bb[4], p[1]);
						bb[5] = max(bb[5], p[2]);
					}
				}
			}
			surf->deprecatedq3data_collisionbbox6f = tv_bbox[s];
		}
		printf("SF\t%d\t%d\t%d\t%d\t%d", s, tv_stex[s], tv_stride[s], TV_SV, TV_ST);
		tv_pv(surf->mins);
		tv_pv(surf->maxs);
		printf("\nSV");
		for (i = 0; i < TV_SV * 3; i++)
			tv_pf(tv_lvert[s][i]);
		printf("\nSE");
		for (i = 0; i < TV_ST * 3; i++)
			printf("\t%d", tv_lelem[s][i]);
		printf("\nSR");
		for (i = 0; i < TV_SV * 3; i++)
			tv_pf(tv_rvert[s * TV_SV * 3 + i]);
		printf("\nSB");
		for (i = 0; i < groups * 6; i++)
			tv_pf(tv_bbox[s][i]);
		printf("\n");
	}
}

// ---- BSP tree over the world brushes and surfaces
#define TV_MAXNODES 512
static mplane_t tv_plane[TV_MAXNODES];
static mnode_t tv_node[TV_MAXNODES];
static mleaf_t tv_leaf[TV_MAXNODES];
static int tv_leafbrushes[TV_MAXNODES * TV_NB], tv_leafsurfaces[TV_MAXNODES * TV_NS];
static int tv_numnodes, tv_numleafs, tv_numleafbrushes, tv_numleafsurfaces;

static mnode_t *tv_build(const int *blist, int nb, const int *slist, int ns, const float *mins, const float *maxs, int depth)
{
	int i, j, axis, sides, nf = 0, nbk = 0, nsf = 0, nsb = 0;
	int *fl, *bl, *sfl, *sbl;
	float fmins[3], fmaxs[3], bmins[3], bmaxs[3], c[3];
	mnode_t *node;
	mplane_t *plane;
	if (nb <= 3 || depth >= 7 || tv_numnodes >= TV_MAXNODES - 1)
	{
		mleaf_t *leaf = tv_leaf + tv_numleafs++;
		memset(leaf, 0, sizeof(*leaf));
		VectorCopy(mins, leaf->mins);
		VectorCopy(maxs, leaf->maxs);
		leaf->clusterindex = (tv_rnd() % 10) < 3 ? -1 : (int)(tv_rnd() % 40);
		leaf->numleafbrushes = nb;
		leaf->firstleafbrush = tv_leafbrushes + tv_numleafbrushes;
		for (i = 0; i < nb; i++)
			tv_leafbrushes[tv_numleafbrushes++] = blist[i];
		leaf->numleafsurfaces = ns;
		leaf->firstleafsurface = tv_leafsurfaces + tv_numleafsurfaces;
		for (i = 0; i < ns; i++)
			tv_leafsurfaces[tv_numleafsurfaces++] = slist[i];
		leaf->containscollisionsurfaces = ns > 0;
		return (mnode_t *)leaf;
	}
	node = tv_node + tv_numnodes;
	plane = tv_plane + tv_numnodes;
	tv_numnodes++;
	memset(node, 0, sizeof(*node));
	memset(plane, 0, sizeof(*plane));
	VectorCopy(mins, node->mins);
	VectorCopy(maxs, node->maxs);
	VectorCopy(mins, fmins);
	VectorCopy(maxs, fmaxs);
	VectorCopy(mins, bmins);
	VectorCopy(maxs, bmaxs);
	if (depth % 3 == 2)
	{
		// a plane in any direction through the middle of the brush centers
		VectorClear(c);
		for (i = 0; i < nb; i++)
			VectorAdd(c, tv_bcenter[blist[i]], c);
		tv_randnormal(plane->normal);
		plane->dist = (plane->normal[0] * c[0] + plane->normal[1] * c[1] + plane->normal[2] * c[2]) / (float)nb;
	}
	else
	{
		axis = 0;
		if (maxs[1] - mins[1] > maxs[axis] - mins[axis])
			axis = 1;
		if (maxs[2] - mins[2] > maxs[axis] - mins[axis])
			axis = 2;
		plane->normal[axis] = 1;
		plane->dist = (float)floor((mins[axis] + maxs[axis]) * 0.5f + tv_frand(-20, 20));
		fmins[axis] = plane->dist;
		bmaxs[axis] = plane->dist;
	}
	PlaneClassify(plane);
	node->plane = plane;
	fl = (int *)malloc(sizeof(int) * (nb + 1) * 2);
	bl = fl + nb + 1;
	sfl = (int *)malloc(sizeof(int) * (ns + 1) * 2);
	sbl = sfl + ns + 1;
	for (i = 0; i < nb; i++)
	{
		const colbrushf_t *b = tv_brush[blist[i]].colbrushf;
		sides = b ? BoxOnPlaneSide(b->mins, b->maxs, plane) : 3;
		if (sides & 1)
			fl[nf++] = blist[i];
		if (sides & 2)
			bl[nbk++] = blist[i];
	}
	for (i = 0; i < ns; i++)
	{
		sides = BoxOnPlaneSide(tv_surf[slist[i]].mins, tv_surf[slist[i]].maxs, plane);
		if (sides & 1)
			sfl[nsf++] = slist[i];
		if (sides & 2)
			sbl[nsb++] = slist[i];
	}
	(void)j;
	node->children[0] = tv_build(fl, nf, sfl, nsf, fmins, fmaxs, depth + 1);
	node->children[1] = tv_build(bl, nbk, sbl, nsb, bmins, bmaxs, depth + 1);
	free(fl);
	free(sfl);
	return node;
}
static int tv_childnum(const mnode_t *n) // >= 0: node index, < 0: -(leaf index + 1)
{
	if (n->plane)
		return (int)(n - tv_node);
	return -((int)((const mleaf_t *)n - tv_leaf) + 1);
}
static void tv_makebsp(void)
{
	int blist[TV_NWORLDB], slist[TV_NWORLDS], i;
	float mins[3] = {-640, -640, -640}, maxs[3] = {640, 640, 640};
	for (i = 0; i < TV_NWORLDB; i++)
		blist[i] = i;
	for (i = 0; i < TV_NWORLDS; i++)
		slist[i] = i;
	tv_build(blist, TV_NWORLDB, slist, TV_NWORLDS, mins, maxs, 0);
	printf("BSP\t%d\t%d\t%d\t%d\n", tv_numnodes, tv_numleafs, tv_numleafbrushes, tv_numleafsurfaces);
	for (i = 0; i < tv_numnodes; i++)
	{
		printf("ND\t%d", i);
		tv_pv(tv_plane[i].normal);
		tv_pf(tv_plane[i].dist);
		printf("\t%d\t%d\t%d\t%d", tv_plane[i].type, tv_plane[i].signbits, tv_childnum(tv_node[i].children[0]), tv_childnum(tv_node[i].children[1]));
		tv_pv(tv_node[i].mins);
		tv_pv(tv_node[i].maxs);
		printf("\n");
	}
	for (i = 0; i < tv_numleafs; i++)
	{
		printf("LF\t%d\t%d\t%d\t%d\t%d\t%d\t%d", i, tv_leaf[i].clusterindex, tv_leaf[i].containscollisionsurfaces, tv_leaf[i].numleafsurfaces,
			(int)(tv_leaf[i].firstleafsurface - tv_leafsurfaces), tv_leaf[i].numleafbrushes, (int)(tv_leaf[i].firstleafbrush - tv_leafbrushes));
		tv_pv(tv_leaf[i].mins);
		tv_pv(tv_leaf[i].maxs);
		printf("\n");
	}
	printf("LB");
	for (i = 0; i < tv_numleafbrushes; i++)
		printf("\t%d", tv_leafbrushes[i]);
	printf("\nLS");
	for (i = 0; i < tv_numleafsurfaces; i++)
		printf("\t%d", tv_leafsurfaces[i]);
	printf("\n");
}

// ---- the two models: the world (submodel 0) and submodel 1, which shares all arrays
static dp_model_t tv_model[2];
static void tv_makemodels(void)
{
	dp_model_t *w = tv_model + 0, *s = tv_model + 1;
	memset(tv_model, 0, sizeof(tv_model));
	w->data_textures = tv_tex;
	w->data_surfaces = tv_surf;
	w->brush.data_brushes = tv_brush;
	w->brush.data_nodes = tv_node;
	w->brush.data_leafs = tv_leaf;
	w->brush.data_collisionvertex3f = tv_cvert;
	w->brush.data_collisionelement3i = tv_celem;
	w->surfmesh.data_vertex3f = tv_rvert;
	w->surfmesh.data_element3i = tv_relem;
	// the function pointers Mod_Q3BSP_Load sets
	w->TraceBox = Mod_Q3BSP_TraceBox;
	w->TraceBrush = Mod_Q3BSP_TraceBrush;
	w->TraceLine = Mod_Q3BSP_TraceLine;
	w->TracePoint = Mod_Q3BSP_TracePoint;
	w->PointSuperContents = Mod_Q3BSP_PointSuperContents;
	w->TraceLineAgainstSurfaces = Mod_CollisionBIH_TraceLine;
	*s = *w;
	w->brush.submodel = 0;
	w->firstmodelbrush = 0;
	w->nummodelbrushes = TV_NWORLDB;
	w->firstmodelsurface = 0;
	w->nummodelsurfaces = TV_NWORLDS;
	s->brush.submodel = 1;
	s->firstmodelbrush = TV_NWORLDB;
	s->nummodelbrushes = TV_NB - TV_NWORLDB;
	s->firstmodelsurface = TV_NWORLDS;
	s->nummodelsurfaces = TV_NS - TV_NWORLDS;
	loadmodel = w;
	Mod_MakeCollisionBIH(w, false, &w->collision_bih);
	Mod_MakeCollisionBIH(w, true, &w->render_bih);
	Mod_MakeCollisionBIH(s, false, &s->collision_bih);
	Mod_MakeCollisionBIH(s, true, &s->render_bih);
	printf("MODEL\t0\t%d\t%d\t%d\t%d\t%d\t%d\n", w->firstmodelbrush, w->nummodelbrushes, w->firstmodelsurface, w->nummodelsurfaces,
		w->collision_bih.numnodes, w->render_bih.numnodes);
	printf("MODEL\t1\t%d\t%d\t%d\t%d\t%d\t%d\n", s->firstmodelbrush, s->nummodelbrushes, s->firstmodelsurface, s->nummodelsurfaces,
		s->collision_bih.numnodes, s->render_bih.numnodes);
}

// a line that mostly aims at something of model m (what: 0 anything, 1 a surface)
static int tv_lastaim = -1; // the brush the last line was aimed at, or -1
static void tv_aim(int m, float *start, float *end, int what)
{
	float c[3], dir[3], d2[3], a, b;
	int j, r = (int)(tv_rnd() % 20), mode;
	tv_lastaim = -1;
	if (what == 1)
		r = 12 + (int)(tv_rnd() % 5);
	if (r < 12)
	{
		tv_lastaim = tv_pickbrush(m);
		VectorCopy(tv_bcenter[tv_lastaim], c);
	}
	else if (r < 17)
		VectorCopy(tv_scenter[m ? TV_NWORLDS : (int)(tv_rnd() % TV_NWORLDS)], c);
	else
	{
		for (j = 0; j < 3; j++)
			c[j] = (m && j == 0 ? 800.0f : 0.0f) + tv_frand(-300, 300);
	}
	for (j = 0; j < 3; j++)
		c[j] += tv_frand(-30, 30);
	tv_randnormal(dir);
	mode = (int)(tv_rnd() % 8);
	if (mode < 4)
	{
		a = tv_frand(60, 500);
		b = tv_frand(0, 250);
		for (j = 0; j < 3; j++)
		{
			start[j] = c[j] + dir[j] * a;
			end[j] = c[j] - dir[j] * b;
		}
	}
	else if (mode < 6) // may start inside
	{
		a = tv_frand(1, 300);
		for (j = 0; j < 3; j++)
		{
			start[j] = c[j];
			end[j] = c[j] + dir[j] * a;
		}
	}
	else if (mode == 6) // does not move
	{
		a = tv_frand(0, 60);
		for (j = 0; j < 3; j++)
			start[j] = end[j] = c[j] + dir[j] * a;
	}
	else
	{
		a = tv_frand(100, 400);
		b = tv_frand(5, 200);
		tv_randnormal(d2);
		for (j = 0; j < 3; j++)
		{
			start[j] = c[j] + dir[j] * a;
			end[j] = start[j] + d2[j] * b;
		}
	}
}
static void tv_boxsize(float *mins, float *maxs)
{
	int j, r = (int)(tv_rnd() % 10);
	if (r == 0)
	{
		VectorClear(mins);
		VectorClear(maxs);
	}
	else if (r < 4) // the player box
	{
		VectorSet(mins, -16, -16, -24);
		VectorSet(maxs, 16, 16, 45);
	}
	else
	{
		for (j = 0; j < 3; j++)
		{
			mins[j] = -tv_frand(1, 40);
			maxs[j] = tv_frand(1, 40);
		}
	}
}

// ---- collision.c functions one at a time, against a list of brushes (state printed whenever it changes)
static void tv_boxt(int kind) // 0: box, 1: the same boxes with isaabb cleared (all separating axes are tried)
{
	colboxbrushf_t bs, be;
	trace_t t, prev;
	float start[3], end[3], mins[3], maxs[3], smins[3], smaxs[3], emins[3], emaxs[3];
	int list[8], i, hit, skip, mat, bsc, bq3;
	const texture_t *btex;
	tv_aim(0, start, end, 0);
	tv_boxsize(mins, maxs);
	VectorAdd(start, mins, smins);
	VectorAdd(start, maxs, smaxs);
	VectorAdd(end, mins, emins);
	VectorAdd(end, maxs, emaxs);
	tv_masks(&hit, &skip, &mat);
	bsc = (int)(tv_rnd() % 3);
	bq3 = (int)(tv_rnd() % 4) << 4;
	btex = (tv_rnd() % 3) ? tv_tex + (tv_rnd() % TV_NTEX) : NULL;
	Collision_BrushForBox(&bs, smins, smaxs, bsc, bq3, btex);
	Collision_BrushForBox(&be, emins, emaxs, bsc, bq3, btex);
	if (kind == 1)
		bs.brush.isaabb = be.brush.isaabb = false;
	for (i = 0; i < 8; i++)
		list[i] = tv_pickbrush(tv_rnd() % 6 == 0);
	if (tv_lastaim >= 0)
		list[tv_rnd() % 8] = tv_lastaim;
	printf("BOXT\t%d\t%d\t%d\t%d\t%d\t%d\t%d", kind, hit, skip, mat, bsc, bq3, tv_texidx(btex));
	tv_pv(smins);
	tv_pv(smaxs);
	tv_pv(emins);
	tv_pv(emaxs);
	for (i = 0; i < 8; i++)
		printf("\t%d", list[i]);
	printf("\n");
	tv_tinit(&t, hit, skip, mat);
	for (i = 0; i < 8; i++)
	{
		prev = t;
		Collision_TraceBrushBrushFloat(&t, &bs.brush, &be.brush, tv_brush[list[i]].colbrushf, tv_brush[list[i]].colbrushf);
		if (memcmp(&prev, &t, sizeof(t)))
			tv_state("S", i, &t);
	}
	tv_state("E", 0, &t);
}
static void tv_movet(void) // a box against a box that moves too (other_start != other_end)
{
	colboxbrushf_t bs, be, os, oe;
	trace_t t;
	float start[3], end[3], mins[3], maxs[3], smins[3], smaxs[3], emins[3], emaxs[3], osmins[3], osmaxs[3], oemins[3], oemaxs[3], d[3];
	int j, hit, skip, mat, tex = (int)(tv_rnd() % TV_NTEX);
	tv_aim(0, start, end, 0);
	tv_boxsize(mins, maxs);
	VectorAdd(start, mins, smins);
	VectorAdd(start, maxs, smaxs);
	VectorAdd(end, mins, emins);
	VectorAdd(end, maxs, emaxs);
	for (j = 0; j < 3; j++)
	{
		float c = (start[j] + end[j]) * 0.5f + tv_frand(-40, 40);
		osmins[j] = c - tv_frand(4, 60);
		osmaxs[j] = c + tv_frand(4, 60);
		d[j] = tv_frand(-80, 80);
	}
	VectorAdd(osmins, d, oemins);
	VectorAdd(osmaxs, d, oemaxs);
	tv_masks(&hit, &skip, &mat);
	Collision_BrushForBox(&bs, smins, smaxs, 0, 0, NULL);
	Collision_BrushForBox(&be, emins, emaxs, 0, 0, NULL);
	Collision_BrushForBox(&os, osmins, osmaxs, tv_tex[tex].supercontents, tv_tex[tex].surfaceflags, tv_tex + tex);
	Collision_BrushForBox(&oe, oemins, oemaxs, tv_tex[tex].supercontents, tv_tex[tex].surfaceflags, tv_tex + tex);
	bs.brush.isaabb = be.brush.isaabb = false;
	printf("MOVET\t%d\t%d\t%d\t%d", hit, skip, mat, tex);
	tv_pv(smins);
	tv_pv(smaxs);
	tv_pv(emins);
	tv_pv(emaxs);
	tv_pv(osmins);
	tv_pv(osmaxs);
	tv_pv(oemins);
	tv_pv(oemaxs);
	printf("\n");
	tv_tinit(&t, hit, skip, mat);
	Collision_TraceBrushBrushFloat(&t, &bs.brush, &be.brush, &os.brush, &oe.brush);
	tv_state("E", 0, &t);
}
static void tv_linet(void)
{
	trace_t t, prev;
	float start[3], end[3];
	int list[8], i, hit, skip, mat;
	tv_aim(0, start, end, 0);
	tv_masks(&hit, &skip, &mat);
	for (i = 0; i < 8; i++)
		list[i] = tv_pickbrush(tv_rnd() % 6 == 0);
	if (tv_lastaim >= 0)
		list[tv_rnd() % 8] = tv_lastaim;
	printf("LINET\t%d\t%d\t%d", hit, skip, mat);
	tv_pv(start);
	tv_pv(end);
	for (i = 0; i < 8; i++)
		printf("\t%d", list[i]);
	printf("\n");
	tv_tinit(&t, hit, skip, mat);
	for (i = 0; i < 8; i++)
	{
		prev = t;
		Collision_TraceLineBrushFloat(&t, start, end, tv_brush[list[i]].colbrushf, tv_brush[list[i]].colbrushf);
		if (memcmp(&prev, &t, sizeof(t)))
			tv_state("S", i, &t);
	}
	tv_state("E", 0, &t);
}
static void tv_pntt(void)
{
	trace_t t, prev;
	float p[3];
	int list[8], i, j, hit, skip, mat;
	tv_masks(&hit, &skip, &mat);
	list[0] = tv_pickbrush(0);
	for (j = 0; j < 3; j++)
		p[j] = tv_bcenter[list[0]][j] + tv_frand(-45, 45);
	for (i = 1; i < 8; i++)
		list[i] = tv_pickbrush(tv_rnd() % 6 == 0);
	printf("PNTT\t%d\t%d\t%d", hit, skip, mat);
	tv_pv(p);
	for (i = 0; i < 8; i++)
		printf("\t%d", list[i]);
	printf("\nI");
	for (i = 0; i < 8; i++)
		printf("\t%d", (int)Collision_PointInsideBrushFloat(p, tv_brush[list[i]].colbrushf));
	printf("\n");
	tv_tinit(&t, hit, skip, mat);
	for (i = 0; i < 8; i++)
	{
		prev = t;
		Collision_TracePointBrushFloat(&t, p, tv_brush[list[i]].colbrushf);
		if (memcmp(&prev, &t, sizeof(t)))
			tv_state("S", i, &t);
	}
	tv_state("E", 0, &t);
}
static void tv_tri(int kind)
{
	colpointf_t points[3], edgedirs[3];
	colplanef_t planes[5];
	colbrushf_t brush;
	int i, j;
	float a, b;
	memset(points, 0, sizeof(points));
	memset(edgedirs, 0, sizeof(edgedirs));
	memset(planes, 0, sizeof(planes));
	memset(&brush, 0, sizeof(brush));
	for (i = 0; i < 3; i++)
		for (j = 0; j < 3; j++)
			points[i].v[j] = tv_frand(-200, 200);
	switch (kind % 8)
	{
	case 0: // two corners in the same place
		VectorCopy(points[0].v, points[1].v);
		break;
	case 1: // the three corners on one line
		a = tv_frand(0, 1);
		for (j = 0; j < 3; j++)
			points[2].v[j] = points[0].v[j] + (points[1].v[j] - points[0].v[j]) * a;
		break;
	case 2: // flat on an axis plane, on whole numbers
		for (i = 0; i < 3; i++)
		{
			for (j = 0; j < 3; j++)
				points[i].v[j] = (float)floor(points[i].v[j]);
			points[i].v[kind % 3] = 64;
		}
		break;
	case 3: // small
		a = tv_frand(0.01f, 0.4f);
		b = tv_frand(0.01f, 0.4f);
		for (j = 0; j < 3; j++)
		{
			points[1].v[j] = points[0].v[j] + (j == 0 ? a : 0.0f);
			points[2].v[j] = points[0].v[j] + (j == 1 ? b : 0.0f);
		}
		break;
	case 4: // normal with two equal components (the axis choice has a tie)
		VectorSet(points[0].v, 8, 0, 0);
		VectorSet(points[1].v, 0, 8, 0);
		VectorSet(points[2].v, 0, 0, tv_frand(1, 30));
		break;
	default:
		break;
	}
	brush.numpoints = 3;
	brush.numedgedirs = 3;
	brush.numplanes = 5;
	brush.points = points;
	brush.edgedirs = edgedirs;
	brush.planes = planes;
	printf("TRI");
	for (i = 0; i < 3; i++)
		tv_pv(points[i].v);
	Collision_CalcPlanesForTriangleBrushFloat(&brush);
	printf("\t%d\t%d", brush.numplanes, brush.numedgedirs);
	for (i = 0; i < 5; i++)
	{
		tv_pv(planes[i].normal);
		tv_pf(planes[i].dist);
	}
	for (i = 0; i < 3; i++)
		tv_pv(edgedirs[i].v);
	printf("\n");
}
static void tv_seg(void)
{
	colboxbrushf_t bs, be;
	float start[3], end[3], mins[3], maxs[3], smins[3], smaxs[3], emins[3], emaxs[3], omins[3], omaxs[3], sf, ef;
	tv_aim(0, start, end, 0);
	tv_boxsize(mins, maxs);
	VectorAdd(start, mins, smins);
	VectorAdd(start, maxs, smaxs);
	VectorAdd(end, mins, emins);
	VectorAdd(end, maxs, emaxs);
	Collision_BrushForBox(&bs, smins, smaxs, 0, 0, NULL);
	Collision_BrushForBox(&be, emins, emaxs, 0, 0, NULL);
	sf = tv_frand(0, 1);
	ef = tv_frand(0, 1);
	Collision_BoundingBoxOfBrushTraceSegment(&bs.brush, &be.brush, omins, omaxs, sf, ef);
	printf("SEG");
	tv_pv(smins);
	tv_pv(smaxs);
	tv_pv(emins);
	tv_pv(emaxs);
	tv_pf(sf);
	tv_pf(ef);
	tv_pv(omins);
	tv_pv(omaxs);
	printf("\n");
}
// the triangle mesh functions against one surface, with a stride of the caller's choice
static void tv_mesht(int line)
{
	colboxbrushf_t bs, be;
	trace_t t;
	float start[3], end[3], mins[3], maxs[3], smins[3], smaxs[3], emins[3], emaxs[3], segmins[3], segmaxs[3];
	int j, hit, skip, mat, s = (int)(tv_rnd() % TV_NS), stride, tex = (int)(tv_rnd() % TV_NTEX);
	const msurface_t *surf = tv_surf + s;
	float dir[3], a, b;
	// 0 and -1 work for every surface; a positive stride needs the surface's own bboxes
	if (tv_stride[s] > 0 && tv_rnd() % 2)
		stride = tv_stride[s];
	else
		stride = (int)(tv_rnd() % 2) - 1;
	if (line || tv_rnd() % 2)
	{
		// mostly across the surface, from either side
		dir[0] = tv_frand(-0.3f, 0.3f);
		dir[1] = tv_frand(-0.3f, 0.3f);
		dir[2] = tv_rnd() % 2 ? 1.0f : -1.0f;
	}
	else
		tv_randnormal(dir);
	a = tv_frand(20, 200);
	b = tv_frand(0, 120);
	for (j = 0; j < 3; j++)
	{
		float c = tv_scenter[s][j] + tv_frand(-90, 90);
		start[j] = c + dir[j] * a;
		end[j] = c - dir[j] * b;
	}
	tv_boxsize(mins, maxs);
	if (line)
	{
		VectorClear(mins);
		VectorClear(maxs);
	}
	VectorAdd(start, mins, smins);
	VectorAdd(start, maxs, smaxs);
	VectorAdd(end, mins, emins);
	VectorAdd(end, maxs, emaxs);
	for (j = 0; j < 3; j++)
	{
		segmins[j] = min(smins[j], emins[j]) - 1;
		segmaxs[j] = max(smaxs[j], emaxs[j]) + 1;
	}
	tv_masks(&hit, &skip, &mat);
	printf("MESHT\t%d\t%d\t%d\t%d\t%d\t%d\t%d", line, s, stride, tex, hit, skip, mat);
	tv_pv(smins);
	tv_pv(smaxs);
	tv_pv(emins);
	tv_pv(emaxs);
	tv_pv(segmins);
	tv_pv(segmaxs);
	printf("\n");
	tv_tinit(&t, hit, skip, mat);
	if (line)
		Collision_TraceLineTriangleMeshFloat(&t, smins, emins, surf->num_collisiontriangles, surf->deprecatedq3data_collisionelement3i,
			surf->deprecatedq3data_collisionvertex3f, stride, surf->deprecatedq3data_collisionbbox6f, tv_tex[tex].supercontents,
			tv_tex[tex].surfaceflags, tv_tex + tex, segmins, segmaxs);
	else
	{
		Collision_BrushForBox(&bs, smins, smaxs, 0, 0, NULL);
		Collision_BrushForBox(&be, emins, emaxs, 0, 0, NULL);
		Collision_TraceBrushTriangleMeshFloat(&t, &bs.brush, &be.brush, surf->num_collisiontriangles, surf->deprecatedq3data_collisionelement3i,
			surf->deprecatedq3data_collisionvertex3f, stride, surf->deprecatedq3data_collisionbbox6f, tv_tex[tex].supercontents,
			tv_tex[tex].surfaceflags, tv_tex + tex, segmins, segmaxs);
	}
	tv_state("E", 0, &t);
}

// ---- the model's trace functions
static void tv_xbox(int m)
{
	trace_t t;
	float start[3], end[3], mins[3], maxs[3];
	int hit, skip, mat;
	tv_aim(m, start, end, 0);
	tv_boxsize(mins, maxs);
	tv_masks(&hit, &skip, &mat);
	printf("XBOX\t%d\t%d\t%d\t%d", m, hit, skip, mat);
	tv_pv(start);
	tv_pv(mins);
	tv_pv(maxs);
	tv_pv(end);
	printf("\n");
	Mod_Q3BSP_TraceBox(tv_model + m, NULL, NULL, &t, start, mins, maxs, end, hit, skip, mat);
	tv_state("E", 0, &t);
}
static void tv_xnbox(int m) // Mod_Q3BSP_TraceBrush with boxes that are not marked as axis aligned
{
	colboxbrushf_t bs, be;
	trace_t t;
	float start[3], end[3], mins[3], maxs[3], smins[3], smaxs[3], emins[3], emaxs[3];
	int hit, skip, mat;
	tv_aim(m, start, end, 0);
	tv_boxsize(mins, maxs);
	VectorAdd(start, mins, smins);
	VectorAdd(start, maxs, smaxs);
	VectorAdd(end, mins, emins);
	VectorAdd(end, maxs, emaxs);
	tv_masks(&hit, &skip, &mat);
	Collision_BrushForBox(&bs, smins, smaxs, 0, 0, NULL);
	Collision_BrushForBox(&be, emins, emaxs, 0, 0, NULL);
	bs.brush.isaabb = be.brush.isaabb = false;
	printf("XNBOX\t%d\t%d\t%d\t%d", m, hit, skip, mat);
	tv_pv(smins);
	tv_pv(smaxs);
	tv_pv(emins);
	tv_pv(emaxs);
	printf("\n");
	Mod_Q3BSP_TraceBrush(tv_model + m, NULL, NULL, &t, &bs.brush, &be.brush, hit, skip, mat);
	tv_state("E", 0, &t);
}
static void tv_xline(int m, int surfaces)
{
	trace_t t;
	float start[3], end[3];
	int hit, skip, mat;
	tv_aim(m, start, end, surfaces);
	tv_masks(&hit, &skip, &mat);
	printf("%s\t%d\t%d\t%d\t%d", surfaces ? "XSURF" : "XLINE", m, hit, skip, mat);
	tv_pv(start);
	tv_pv(end);
	printf("\n");
	if (surfaces)
		Mod_CollisionBIH_TraceLineAgainstSurfaces(tv_model + m, NULL, NULL, &t, start, end, hit, skip, mat);
	else
		Mod_Q3BSP_TraceLine(tv_model + m, NULL, NULL, &t, start, end, hit, skip, mat);
	tv_state("E", 0, &t);
}
static void tv_xpoint(int m)
{
	trace_t t;
	float p[3];
	int j, b = tv_pickbrush(m), hit, skip, mat;
	for (j = 0; j < 3; j++)
		p[j] = tv_bcenter[b][j] + tv_frand(-90, 90);
	tv_masks(&hit, &skip, &mat);
	printf("XPOINT\t%d\t%d\t%d\t%d", m, hit, skip, mat);
	tv_pv(p);
	printf("\n");
	Mod_Q3BSP_TracePoint(tv_model + m, NULL, NULL, &t, p, hit, skip, mat);
	tv_state("E", 0, &t);
	printf("XPSC\t%d", m);
	tv_pv(p);
	printf("\t%d\n", Mod_Q3BSP_PointSuperContents(tv_model + m, 0, p));
}
static void tv_xlos(int m)
{
	float start[3], end[3], amins[3], amaxs[3];
	int j, r = (int)(tv_rnd() % 4);
	tv_aim(m, start, end, 0);
	for (j = 0; j < 3; j++)
	{
		float c = r == 0 ? 0.0f : end[j];
		amins[j] = c - tv_frand(1, 60);
		amaxs[j] = c + tv_frand(1, 60);
	}
	printf("XLOS\t%d", m);
	tv_pv(start);
	tv_pv(end);
	tv_pv(amins);
	tv_pv(amaxs);
	printf("\t%d\n", (int)Mod_Q3BSP_TraceLineOfSight(tv_model + m, start, end, amins, amaxs));
}

// ---- collision.c Collision_ClipTo* / Collision_CombineTraces: a world trace, then the submodel and plain
// boxes as entities with a matrix, combined the way SV_TraceBox combines them
static matrix4x4_t tv_mat, tv_imat;
static void tv_setmatrix(int kind, const float *origin)
{
	double a[3] = {0, 0, 0}, scale = 1;
	int i, j;
	switch (kind)
	{
	case 1: // yaw
		a[1] = tv_frand(-180, 180);
		break;
	case 2: // pitch and yaw
		a[0] = tv_frand(-80, 80);
		a[1] = tv_frand(-180, 180);
		break;
	case 3: // all three
		a[0] = tv_frand(-80, 80);
		a[1] = tv_frand(-180, 180);
		a[2] = tv_frand(-60, 60);
		break;
	case 4: // yaw and scale
		a[1] = tv_frand(-180, 180);
		scale = tv_frand(0.5f, 2);
		break;
	default: // translation only
		break;
	}
	Matrix4x4_CreateFromQuakeEntity(&tv_mat, origin[0], origin[1], origin[2], a[0], a[1], a[2], scale);
	Matrix4x4_Invert_Simple(&tv_imat, &tv_mat);
	printf("MATIN\t%016llx\t%016llx\t%016llx\t%016llx\t%016llx\t%016llx\t%016llx\n", tv_dbits(origin[0]), tv_dbits(origin[1]),
		tv_dbits(origin[2]), tv_dbits(a[0]), tv_dbits(a[1]), tv_dbits(a[2]), tv_dbits(scale));
	printf("MAT");
	for (i = 0; i < 4; i++)
		for (j = 0; j < 4; j++)
			tv_pf(tv_mat.m[i][j]);
	for (i = 0; i < 4; i++)
		for (j = 0; j < 4; j++)
			tv_pf(tv_imat.m[i][j]);
	printf("\n");
}
static void tv_endpos(const trace_t *t)
{
	printf("EP\t%016llx\t%016llx\t%016llx\n", tv_dbits(t->endpos[0]), tv_dbits(t->endpos[1]), tv_dbits(t->endpos[2]));
}
static void tv_clipstate(const trace_t *t) // every field Collision_CombineTraces touches
{
	printf("CS\t%d\t%d\t%d\t%d\t%016llx\t%016llx\t%016llx\t%016llx", t->allsolid, t->startsolid, t->bmodelstartsolid, t->inwater,
		tv_dbits(t->fraction), tv_dbits(t->endpos[0]), tv_dbits(t->endpos[1]), tv_dbits(t->endpos[2]));
	tv_pv(t->plane.normal);
	tv_pf(t->plane.dist);
	printf("\t%d\t%d\t%d\t%d\t%d\t%016llx\t%016llx\t%016llx\t%016llx\n", (int)(intptr_t)t->ent, t->hitsupercontents, t->hitq3surfaceflags,
		tv_texidx(t->hittexture), t->startsupercontents, tv_dbits(t->startdepth), tv_dbits(t->startdepthnormal[0]),
		tv_dbits(t->startdepthnormal[1]), tv_dbits(t->startdepthnormal[2]));
}
static void tv_clipscene(void)
{
	static const float extends[5] = {0, 0, 1, 16, 0.03125f};
	static const int bodycontents[3] = {1, 0x20, 2};
	trace_t clip, t;
	float start[3], end[3], mins[3], maxs[3], lstart[3], lend[3], wstart[3], wend[3], origin[3], bodymins[3], bodymaxs[3], dir[3], extend, a, b;
	int hit, skip, mat, j, k, kind = (int)(tv_rnd() % 3), hitsurfaces, usemodel, bodysc, isbmodel;
	tv_aim(0, start, end, 0);
	tv_boxsize(mins, maxs);
	tv_masks(&hit, &skip, &mat);
	extend = extends[tv_rnd() % 5];
	hitsurfaces = (int)(tv_rnd() % 2);
	if (kind == 0)
	{
		printf("XCW\t0\t%d\t%d\t%d", hit, skip, mat);
		tv_pv(start);
		tv_pv(mins);
		tv_pv(maxs);
		tv_pv(end);
		tv_pf(extend);
		printf("\n");
		Collision_ClipToWorld(&t, tv_model, start, mins, maxs, end, hit, skip, mat, extend);
	}
	else if (kind == 1)
	{
		printf("XCLW\t0\t%d\t%d\t%d", hit, skip, mat);
		tv_pv(start);
		tv_pv(end);
		tv_pf(extend);
		printf("\t%d\n", hitsurfaces);
		Collision_ClipLineToWorld(&t, tv_model, start, end, hit, skip, mat, extend, hitsurfaces);
	}
	else
	{
		printf("XCPW\t0\t%d\t%d\t%d", hit, skip, mat);
		tv_pv(start);
		printf("\n");
		Collision_ClipPointToWorld(&t, tv_model, start, hit, skip, mat);
	}
	tv_state("E", 0, &t);
	tv_endpos(&t);
	printf("SETCLIP\n");
	clip = t;
	for (k = 0; k < 3; k++)
	{
		usemodel = (tv_rnd() % 4) != 0;
		bodysc = bodycontents[tv_rnd() % 3];
		for (j = 0; j < 3; j++)
			origin[j] = tv_frand(-200, 200);
		if (usemodel)
		{
			// a line in the submodel's own space, moved into the world by the entity matrix
			tv_aim(1, lstart, lend, 0);
			VectorSet(bodymins, -8, -8, -8);
			VectorSet(bodymaxs, 8, 8, 8);
			tv_setmatrix((int)(tv_rnd() % 5), origin);
		}
		else
		{
			// a plain box body (no model): the matrix has no rotation, as SV_TraceBox ensures
			tv_boxsize(bodymins, bodymaxs);
			if (VectorCompare(bodymins, bodymaxs))
			{
				VectorSet(bodymins, -16, -16, -24);
				VectorSet(bodymaxs, 16, 16, 45);
			}
			tv_randnormal(dir);
			a = kind == 2 ? tv_frand(0, 40) : tv_frand(30, 220); // point traces: often inside the box
			b = tv_frand(-40, 120);
			for (j = 0; j < 3; j++)
			{
				float c = tv_frand(-12, 12);
				lstart[j] = c + dir[j] * a;
				lend[j] = c - dir[j] * b;
			}
			if (tv_rnd() % 6 == 0)
				VectorCopy(lstart, lend);
			tv_setmatrix(0, origin);
		}
		Matrix4x4_Transform(&tv_mat, lstart, wstart);
		Matrix4x4_Transform(&tv_mat, lend, wend);
		if (kind == 0)
		{
			printf("XCG\t%d\t%d\t%d\t%d\t%d", usemodel ? 1 : -1, hit, skip, mat, bodysc);
			tv_pv(bodymins);
			tv_pv(bodymaxs);
			tv_pv(wstart);
			tv_pv(mins);
			tv_pv(maxs);
			tv_pv(wend);
			tv_pf(extend);
			printf("\n");
			Collision_ClipToGenericEntity(&t, usemodel ? tv_model + 1 : NULL, NULL, NULL, bodymins, bodymaxs, bodysc, &tv_mat, &tv_imat,
				wstart, mins, maxs, wend, hit, skip, mat, extend);
		}
		else if (kind == 1)
		{
			printf("XCLG\t%d\t%d\t%d\t%d\t%d", usemodel ? 1 : -1, hit, skip, mat, bodysc);
			tv_pv(bodymins);
			tv_pv(bodymaxs);
			tv_pv(wstart);
			tv_pv(wend);
			tv_pf(extend);
			printf("\t%d\n", hitsurfaces);
			Collision_ClipLineToGenericEntity(&t, usemodel ? tv_model + 1 : NULL, NULL, NULL, bodymins, bodymaxs, bodysc, &tv_mat, &tv_imat,
				wstart, wend, hit, skip, mat, extend, hitsurfaces);
		}
		else
		{
			printf("XCPG\t%d\t%d\t%d\t%d\t%d", usemodel ? 1 : -1, hit, skip, mat, bodysc);
			tv_pv(bodymins);
			tv_pv(bodymaxs);
			tv_pv(wstart);
			printf("\n");
			Collision_ClipPointToGenericEntity(&t, usemodel ? tv_model + 1 : NULL, NULL, NULL, bodymins, bodymaxs, bodysc, &tv_mat, &tv_imat,
				wstart, hit, skip, mat);
		}
		tv_state("E", 0, &t);
		tv_endpos(&t);
		isbmodel = usemodel && (tv_rnd() % 3) != 0;
		printf("COMB\t%d\t%d\n", isbmodel, k + 1);
		Collision_CombineTraces(&clip, &t, (void *)(intptr_t)(k + 1), isbmodel);
		tv_clipstate(&clip);
	}
}

int main(void)
{
	int i, m, bihmode, v;
	tv_seed = 20261126u;

	// what Collision_Init / Mod_BrushInit would have set by registering the cvars
	collision_impactnudge.value = 0.03125f;
	collision_triangle_axialsides.integer = 1;
	mod_q3bsp_curves_collisions.integer = 1;
	mod_q3bsp_optimizedtraceline.integer = 1;
	mod_collision_bih.integer = 1;

	tv_maketextures();
	tv_makebrushes();
	tv_makesurfaces();
	tv_makebsp();
	tv_makemodels();

	// triangle brushes in the three side plane modes
	for (v = 0; v < 3; v++)
	{
		TV_SETCV(collision_triangle_bevelsides, v == 1);
		TV_SETCV(collision_triangle_axialsides, v == 0);
		for (i = 0; i < 40; i++)
			tv_tri(i);
	}
	TV_SETCV(collision_triangle_bevelsides, 0);
	TV_SETCV(collision_triangle_axialsides, 1);

	for (i = 0; i < 24; i++)
		tv_seg();
	for (i = 0; i < 160; i++)
		tv_boxt(i % 4 == 3);
	for (i = 0; i < 40; i++)
		tv_movet();
	for (i = 0; i < 160; i++)
		tv_linet();
	TV_SETCV(collision_debug_tracelineasbox, 1);
	for (i = 0; i < 30; i++)
		tv_linet();
	TV_SETCV(collision_debug_tracelineasbox, 0);
	for (i = 0; i < 60; i++)
		tv_pntt();
	for (v = 0; v < 3; v++)
	{
		TV_SETCV(collision_triangle_bevelsides, v == 1);
		TV_SETCV(collision_triangle_axialsides, v == 0);
		for (i = 0; i < (v ? 20 : 80); i++)
			tv_mesht(i % 2);
	}
	TV_SETCV(collision_triangle_bevelsides, 0);
	TV_SETCV(collision_triangle_axialsides, 1);

	// the model functions: with the BIH (the default) and with the BSP tree / brush list
	for (m = 0; m < 2; m++)
	{
		for (bihmode = 1; bihmode >= 0; bihmode--)
		{
			TV_SETCV(mod_collision_bih, bihmode);
			for (i = 0; i < 70; i++)
				tv_xbox(m);
			for (i = 0; i < 70; i++)
				tv_xline(m, 0);
			for (i = 0; i < 30; i++)
				tv_xpoint(m);
			for (i = 0; i < 16; i++)
				tv_xnbox(m);
			for (i = 0; i < 20; i++)
				tv_xlos(m);
			for (i = 0; i < 20; i++)
				tv_xline(m, 1);
		}
	}
	// debugging / tuning cvars away from their defaults
	for (v = 0; v < 7; v++)
	{
		switch (v)
		{
		case 0: TV_SETCV(mod_q3bsp_curves_collisions, 0); break;
		case 1: TV_SETCV(collision_bih_fullrecursion, 1); break;
		case 2: TV_SETCV(collision_debug_tracelineasbox, 1); break;
		case 3: TV_SETCV(collision_triangle_bevelsides, 1); break;
		case 4: TV_SETCV(collision_triangle_axialsides, 0); break;
		case 5: TV_SETCV(mod_q3bsp_optimizedtraceline, 0); break;
		case 6: TV_SETCV(mod_q3bsp_tracelineofsight_brushes, 1); break;
		}
		for (m = 0; m < 2; m++)
		{
			for (bihmode = 1; bihmode >= 0; bihmode--)
			{
				TV_SETCV(mod_collision_bih, bihmode);
				for (i = 0; i < 12; i++)
					tv_xbox(m);
				for (i = 0; i < 12; i++)
					tv_xline(m, 0);
				for (i = 0; i < 4; i++)
					tv_xlos(m);
			}
		}
		switch (v)
		{
		case 0: TV_SETCV(mod_q3bsp_curves_collisions, 1); break;
		case 1: TV_SETCV(collision_bih_fullrecursion, 0); break;
		case 2: TV_SETCV(collision_debug_tracelineasbox, 0); break;
		case 3: TV_SETCV(collision_triangle_bevelsides, 0); break;
		case 4: TV_SETCV(collision_triangle_axialsides, 1); break;
		case 5: TV_SETCV(mod_q3bsp_optimizedtraceline, 1); break;
		case 6: TV_SETCV(mod_q3bsp_tracelineofsight_brushes, 0); break;
		}
	}
	// Collision_ClipTo*, Collision_CombineTraces (both world paths)
	for (bihmode = 1; bihmode >= 0; bihmode--)
	{
		TV_SETCV(mod_collision_bih, bihmode);
		for (i = 0; i < 90; i++)
			tv_clipscene();
	}
	TV_SETCV(mod_collision_bih, 1);
	printf("END\n");
	return 0;
}
