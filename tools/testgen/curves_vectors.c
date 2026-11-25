// Reference vectors for engine/curves.luau and the mesh helpers of engine/model_shared.luau: the release's
// curves.c and model_shared.c compiled unchanged (curves_vectors.sh; unused functions are dropped by
// --gc-sections). Output: tests/vectors/curves.tsv, floats as bit patterns.
#include "quakedef.h"
#include "curves.h"
#include <stdint.h>

void Con_Print(const char *txt) { (void)txt; }
void Con_Printf(const char *fmt, ...) { (void)fmt; }
void Con_DPrint(const char *msg) { (void)msg; }
void Con_DPrintf(const char *fmt, ...) { (void)fmt; }
void *_Mem_Alloc(mempool_t *pool, void *data, size_t size, size_t alignment, const char *filename, int fileline)
{
	(void)pool; (void)data; (void)alignment; (void)filename; (void)fileline;
	return calloc(1, size + 64);
}

static uint32_t seed;
static uint32_t rnd(void)
{
	seed = seed * 1664525u + 1013904223u;
	return seed >> 8;
}
static float frand(float lo, float hi)
{
	return lo + (hi - lo) * ((float)(int)(rnd() % 4096) / 4096.0f);
}
static uint32_t bits(float f)
{
	uint32_t u;
	memcpy(&u, &f, 4);
	return u;
}
static void floats(const char *tag, const float *f, int n)
{
	int i;
	printf("%s\t%d", tag, n);
	for (i = 0; i < n; i++)
		printf("\t%08x", bits(f[i]));
	printf("\n");
}
static void ints(const char *tag, const int *v, int n)
{
	int i;
	printf("%s\t%d", tag, n);
	for (i = 0; i < n; i++)
		printf("\t%d", v[i]);
	printf("\n");
}

#define MAXV 4096
static float pos[MAXV * 3], tc[MAXV * 2], nrm[MAXV * 3];
static float opos[MAXV * 3], otc[MAXV * 2], onrm[MAXV * 3], svec[MAXV * 3], tvec[MAXV * 3], snapped[MAXV * 3];
static int elem[MAXV * 6], elem2[MAXV * 6];

// mode 0: curved, 1: flat (z constant, x/y on a grid), 2: curved with a collapsed corner (degenerate triangles)
static void makepatch(int w, int h, int mode)
{
	int x, y;
	float ox = frand(-2000, 2000), oy = frand(-2000, 2000), oz = frand(-500, 500);
	for (y = 0; y < h; y++)
		for (x = 0; x < w; x++)
		{
			float *p = pos + (y * w + x) * 3;
			p[0] = ox + x * 48.0f + (mode == 1 ? 0 : frand(-9, 9));
			p[1] = oy + y * 40.0f + (mode == 1 ? 0 : frand(-9, 9));
			p[2] = oz + (mode == 1 ? 0 : frand(-60, 60));
			if (mode == 2 && x < 2 && y < 2)
				VectorCopy(pos, p);
			tc[(y * w + x) * 2 + 0] = x * 0.37f + frand(-0.05f, 0.05f);
			tc[(y * w + x) * 2 + 1] = y * 0.29f + frand(-0.05f, 0.05f);
			nrm[(y * w + x) * 3 + 0] = frand(-0.4f, 0.4f);
			nrm[(y * w + x) * 3 + 1] = frand(-0.4f, 0.4f);
			nrm[(y * w + x) * 3 + 2] = frand(0.6f, 1.0f);
		}
}

static void tess(int w, int h, int tw, int th, int firstvertex, int areaweighting)
{
	int fw = Q3PatchDimForTess(w, tw), fh = Q3PatchDimForTess(h, th), nv = fw * fh, nt = (fw - 1) * (fh - 1) * 2, n;
	if (firstvertex + nv > MAXV)
		return;
	printf("TESS\t%d\t%d\t%d\t%d\t%d\t%d\n", tw, th, fw, fh, firstvertex, areaweighting);
	memset(opos, 0, sizeof(opos));
	memset(otc, 0, sizeof(otc));
	memset(onrm, 0, sizeof(onrm));
	Q3PatchTesselateFloat(3, sizeof(float[3]), opos + firstvertex * 3, w, h, sizeof(float[3]), pos, tw, th);
	Q3PatchTesselateFloat(2, sizeof(float[2]), otc + firstvertex * 2, w, h, sizeof(float[2]), tc, tw, th);
	Q3PatchTesselateFloat(3, sizeof(float[3]), onrm + firstvertex * 3, w, h, sizeof(float[3]), nrm, tw, th);
	floats("OPOS", opos + firstvertex * 3, nv * 3);
	floats("OTC", otc + firstvertex * 2, nv * 2);
	Q3PatchTriangleElements(elem, fw, fh, firstvertex);
	ints("ELEM", elem, nt * 3);
	n = Mod_RemoveDegenerateTriangles(nt, elem, elem2, opos);
	ints("DEGEN", elem2, n * 3);
	memcpy(snapped, opos + firstvertex * 3, nv * sizeof(float[3]));
	Mod_SnapVertices(3, nv, snapped, (tw & 1) ? 1.0f : 0.25f);
	floats("SNAP", snapped, nv * 3);
	Mod_BuildTextureVectorsFromNormals(firstvertex, nv, n, opos, otc, onrm, elem2, svec, tvec, areaweighting);
	floats("SVEC", svec + firstvertex * 3, nv * 3);
	floats("TVEC", tvec + firstvertex * 3, nv * 3);
}

int main(void)
{
	static const int sizes[][2] = {{3, 3}, {3, 5}, {5, 3}, {5, 5}, {7, 5}, {9, 3}, {3, 9}};
	static const float tols[] = {1, 2, 3, 4, 8, 15};
	int i, t, mode;
	seed = 20261126u;
	for (i = 0; i < 28; i++)
	{
		int w = sizes[i % 7][0], h = sizes[i % 7][1], tx[6], ty[6];
		mode = i % 9 == 4 ? 1 : i % 9 == 7 ? 2 : 0;
		makepatch(w, h, mode);
		printf("PATCH\t%d\t%d\t%d\n", w, h, mode);
		floats("POS", pos, w * h * 3);
		floats("TC", tc, w * h * 2);
		floats("NRM", nrm, w * h * 3);
		for (t = 0; t < 6; t++)
		{
			tx[t] = Q3PatchTesselationOnX(w, h, 3, pos, tols[t]);
			ty[t] = Q3PatchTesselationOnY(w, h, 3, pos, tols[t]);
			printf("TOL\t%08x\t%d\t%d\t%d\t%d\n", bits(tols[t]), tx[t], ty[t], Q3PatchTesselationOnX(w, h, 2, tc, tols[t] * 0.001f),
				Q3PatchTesselationOnY(w, h, 2, tc, tols[t] * 0.001f));
		}
		tess(w, h, 0, 0, 0, 1);
		tess(w, h, 1, 2, 5, 0);
		tess(w, h, bound(0, tx[2], 5), bound(0, ty[2], 5), 3, 1);
		tess(w, h, bound(0, tx[5], 4), bound(0, ty[5], 4), 0, 1);
		if (i % 4 == 0)
			tess(w, h, 3, 1, 7, 0);
	}
	// seam fixing: patch B shares an edge (or nothing) with patch A, different tesselation per lod
	for (i = 0; i < 40; i++)
	{
		static float a[81 * 3], b[81 * 3];
		patchinfo_t pa, pb;
		int wa = sizes[i % 7][0], ha = sizes[i % 7][1], wb = sizes[(i * 3 + 1) % 7][0], hb = sizes[(i * 3 + 1) % 7][1], x, y, kind = i % 5, m;
		makepatch(wa, ha, 0);
		memcpy(a, pos, sizeof(float[3]) * wa * ha);
		makepatch(wb, hb, 0);
		memcpy(b, pos, sizeof(float[3]) * wb * hb);
		// kind 0: nothing in common. 1: B's first column = A's last column (needs hb == ha).
		// 2: B's first row = A's last row (needs wb == wa). 3: only one corner in common. 4: B's last row = A's first row reversed.
		if (kind == 1 && hb == ha)
			for (y = 0; y < ha; y++)
				VectorCopy(a + (y * wa + wa - 1) * 3, b + (y * wb) * 3);
		if (kind == 2 && wb == wa)
			for (x = 0; x < wa; x++)
				VectorCopy(a + ((ha - 1) * wa + x) * 3, b + x * 3);
		if (kind == 3)
			VectorCopy(a + (wa * ha - 1) * 3, b);
		if (kind == 4 && wb == wa)
			for (x = 0; x < wa; x++)
				VectorCopy(a + x * 3, b + ((hb - 1) * wb + (wb - 1 - x)) * 3);
		pa.xsize = wa; pa.ysize = ha; pb.xsize = wb; pb.ysize = hb;
		for (m = 0; m < PATCH_LODS_NUM; m++)
		{
			pa.lods[m].xtess = (int)(rnd() % 6); pa.lods[m].ytess = (int)(rnd() % 6);
			pb.lods[m].xtess = (int)(rnd() % 6); pb.lods[m].ytess = (int)(rnd() % 6);
		}
		printf("ADJ\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", wa, ha, wb, hb, pa.lods[0].xtess, pa.lods[0].ytess, pa.lods[1].xtess,
			pa.lods[1].ytess, pb.lods[0].xtess, pb.lods[0].ytess, pb.lods[1].xtess, pb.lods[1].ytess);
		floats("A", a, wa * ha * 3);
		floats("B", b, wb * hb * 3);
		m = Q3PatchAdjustTesselation(3, &pa, a, &pb, b);
		printf("ADJR\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", m, pa.lods[0].xtess, pa.lods[0].ytess, pa.lods[1].xtess, pa.lods[1].ytess,
			pb.lods[0].xtess, pb.lods[0].ytess, pb.lods[1].xtess, pb.lods[1].ytess);
	}
	return 0;
}
