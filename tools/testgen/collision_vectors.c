// Reference vectors for engine/collision.luau (Collision_NewBrushFromPlanes) and engine/polygon.luau: the
// release's collision.c and polygon.c compiled unchanged and linked with the few engine functions they reach
// stubbed (collision_vectors.sh; unused functions are dropped by --gc-sections). Inputs and outputs go to
// tests/vectors/collision.tsv; floats are printed as bit patterns, doubles as 64-bit patterns.
#include "quakedef.h"
#include "polygon.h"
#include "collision.h"
#include <stdint.h>

// ---- stubs for what Collision_NewBrushFromPlanes reaches
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
static float frand(float lo, float hi) // multiples of 1/1024 of the range: plenty of float rounding downstream
{
	return lo + (hi - lo) * ((float)(int)(rnd() % 1024) / 1024.0f);
}
static uint32_t bits(float f)
{
	uint32_t u;
	memcpy(&u, &f, 4);
	return u;
}
static unsigned long long dbits(double d)
{
	unsigned long long u;
	memcpy(&u, &d, 8);
	return u;
}

static texture_t textures[4];
static int brushno;

static void emit(int n, colplanef_t *planes, int supercontents, int q3surfaceflags, int hasaabbplanes)
{
	int i;
	colbrushf_t *b;
	printf("B\t%d\t%d\t%d\t%d\t%d\n", brushno++, n, supercontents, q3surfaceflags, hasaabbplanes);
	for (i = 0; i < n; i++)
		printf("P\t%08x\t%08x\t%08x\t%08x\t%d\t%d\n", bits(planes[i].normal[0]), bits(planes[i].normal[1]), bits(planes[i].normal[2]),
			bits(planes[i].dist), planes[i].q3surfaceflags, (int)(planes[i].texture - textures));
	b = Collision_NewBrushFromPlanes(NULL, n, planes, supercontents, q3surfaceflags, textures + 1, hasaabbplanes);
	if (!b)
	{
		printf("R\tnull\n");
		return;
	}
	printf("R\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%08x\t%08x\t%08x\t%08x\t%08x\t%08x\n", b->isaabb, b->hasaabbplanes, b->supercontents,
		b->q3surfaceflags, (int)(b->texture - textures), b->numplanes, b->numedgedirs, b->numpoints, b->numtriangles,
		bits(b->mins[0]), bits(b->mins[1]), bits(b->mins[2]), bits(b->maxs[0]), bits(b->maxs[1]), bits(b->maxs[2]));
	for (i = 0; i < b->numplanes; i++)
		printf("OP\t%08x\t%08x\t%08x\t%08x\t%d\t%d\n", bits(b->planes[i].normal[0]), bits(b->planes[i].normal[1]),
			bits(b->planes[i].normal[2]), bits(b->planes[i].dist), b->planes[i].q3surfaceflags, (int)(b->planes[i].texture - textures));
	printf("PT");
	for (i = 0; i < b->numpoints; i++)
		printf("\t%08x %08x %08x", bits(b->points[i].v[0]), bits(b->points[i].v[1]), bits(b->points[i].v[2]));
	printf("\nED"); // the memory brush->edgedirs points at, as the engine will read it
	for (i = 0; i < b->numedgedirs; i++)
		printf("\t%08x %08x %08x", bits(b->edgedirs[i].v[0]), bits(b->edgedirs[i].v[1]), bits(b->edgedirs[i].v[2]));
	printf("\nEL");
	for (i = 0; i < b->numtriangles * 3; i++)
		printf("\t%d", b->elements[i]);
	printf("\n");
}

static void setplane(colplanef_t *p, float nx, float ny, float nz, float dist)
{
	p->normal[0] = nx;
	p->normal[1] = ny;
	p->normal[2] = nz;
	p->dist = dist;
	p->q3surfaceflags = (int)(rnd() % 8) << 4;
	p->texture = textures + (rnd() % 4);
}

// the six axial planes in the order q3map2 writes them (+x -x +y -y +z -z)
static int box(colplanef_t *p, const float *mins, const float *maxs)
{
	setplane(p + 0, 1, 0, 0, maxs[0]);
	setplane(p + 1, -1, 0, 0, -mins[0]);
	setplane(p + 2, 0, 1, 0, maxs[1]);
	setplane(p + 3, 0, -1, 0, -mins[1]);
	setplane(p + 4, 0, 0, 1, maxs[2]);
	setplane(p + 5, 0, 0, -1, -mins[2]);
	return 6;
}

static void randnormal(float *n)
{
	float len;
	do
	{
		n[0] = frand(-1, 1);
		n[1] = frand(-1, 1);
		n[2] = frand(-1, 1);
		len = (float)sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
	}
	while (len < 0.2f);
	n[0] /= len;
	n[1] /= len;
	n[2] /= len;
}

int main(void)
{
	static colplanef_t planes[300];
	int i, j, n;
	float mins[3], maxs[3], c[3], nrm[3];
	double quad[12], front[3 * 64], back[3 * 64];
	seed = 20261125u;

	// polygon.c on its own: quads for planes, then one division each
	for (i = 0; i < 60; i++)
	{
		int nf, nb, on, k;
		double d = (double)frand(-3000, 3000), size = 1024.0 * (double)(1 + (int)(rnd() % 8)), pd;
		if (i < 6)
		{
			nrm[0] = (i >> 1) == 0 ? (i & 1 ? -1.0f : 1.0f) : 0.0f;
			nrm[1] = (i >> 1) == 1 ? (i & 1 ? -1.0f : 1.0f) : 0.0f;
			nrm[2] = (i >> 1) == 2 ? (i & 1 ? -1.0f : 1.0f) : 0.0f;
		}
		else
			randnormal(nrm);
		PolygonD_QuadForPlane(quad, nrm[0], nrm[1], nrm[2], d, size);
		printf("QUAD\t%08x\t%08x\t%08x\t%016llx\t%016llx", bits(nrm[0]), bits(nrm[1]), bits(nrm[2]), dbits(d), dbits(size));
		for (k = 0; k < 12; k++)
			printf("\t%016llx", dbits(quad[k]));
		printf("\n");
		randnormal(c);
		pd = (double)frand(-800, 800);
		PolygonD_Divide(4, quad, c[0], c[1], c[2], pd, 0.0625, 64, front, &nf, 64, back, &nb, &on);
		printf("DIV\t%08x\t%08x\t%08x\t%016llx\t%d\t%d\t%d", bits(c[0]), bits(c[1]), bits(c[2]), dbits(pd), nf, nb, on);
		for (k = 0; k < nf * 3; k++)
			printf("\t%016llx", dbits(front[k]));
		printf("\t|");
		for (k = 0; k < nb * 3; k++)
			printf("\t%016llx", dbits(back[k]));
		printf("\n");
	}

	// axis-aligned boxes, as q3map2 writes them
	for (i = 0; i < 40; i++)
	{
		for (j = 0; j < 3; j++)
		{
			c[j] = frand(-4000, 4000);
			mins[j] = c[j] - frand(1, 600);
			maxs[j] = c[j] + frand(1, 600);
		}
		n = box(planes, mins, maxs);
		emit(n, planes, 1, 0, 1);
	}
	// boxes with bevel / cutting planes after the six axial ones (typical map brushes)
	for (i = 0; i < 90; i++)
	{
		int extra = 1 + (int)(rnd() % 10);
		for (j = 0; j < 3; j++)
		{
			c[j] = frand(-3000, 3000);
			mins[j] = c[j] - frand(8, 400);
			maxs[j] = c[j] + frand(8, 400);
		}
		n = box(planes, mins, maxs);
		for (j = 0; j < extra; j++)
		{
			randnormal(nrm);
			// a plane through a point near the box centre, pushed outwards: cuts a corner or an edge
			setplane(planes + n, nrm[0], nrm[1], nrm[2],
				nrm[0] * c[0] + nrm[1] * c[1] + nrm[2] * c[2] + frand(4, 300));
			n++;
		}
		emit(n, planes, (int)(rnd() % 3) + 1, (int)(rnd() % 4), 1);
	}
	// convex polytopes from random planes only (no axial planes first: the bounding box comes from the points)
	for (i = 0; i < 70; i++)
	{
		n = 4 + (int)(rnd() % 28);
		for (j = 0; j < 3; j++)
			c[j] = frand(-2000, 2000);
		for (j = 0; j < n; j++)
		{
			randnormal(nrm);
			setplane(planes + j, nrm[0], nrm[1], nrm[2], nrm[0] * c[0] + nrm[1] * c[1] + nrm[2] * c[2] + frand(16, 256));
		}
		emit(n, planes, 1, 0, 0);
	}
	// degenerate inputs: too few planes, an open brush, a plane that removes everything, duplicated planes
	setplane(planes + 0, 1, 0, 0, 10);
	setplane(planes + 1, 0, 1, 0, 10);
	setplane(planes + 2, 0, 0, 1, 10);
	emit(3, planes, 1, 0, 0);
	mins[0] = mins[1] = mins[2] = -32;
	maxs[0] = maxs[1] = maxs[2] = 32;
	n = box(planes, mins, maxs);
	emit(5, planes, 1, 0, 1); // open on one side
	setplane(planes + 6, 1, 0, 0, -100); // nothing is left
	emit(7, planes, 1, 0, 1);
	n = box(planes, mins, maxs);
	for (j = 0; j < 6; j++)
		planes[6 + j] = planes[j];
	emit(12, planes, 1, 0, 1); // every plane twice
	// many planes around a sphere: lots of points, edge directions and triangles (some hit the buffer limits)
	for (i = 0; i < 6; i++)
	{
		n = 40 + i * 44;
		for (j = 0; j < n; j++)
		{
			randnormal(nrm);
			setplane(planes + j, nrm[0], nrm[1], nrm[2], 512.0f);
		}
		emit(n, planes, 1, 0, 0);
	}
	return 0;
}
