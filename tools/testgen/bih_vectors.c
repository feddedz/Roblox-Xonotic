// Reference vectors for engine/bih.luau: the release's bih.c, compiled unchanged (bih_vectors.sh puts the
// DarkPlaces source directory on the include path). Inputs and outputs go to tests/vectors/bih.tsv; floats are
// printed as bit patterns.
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include "bih.c"

static uint32_t seed;
static uint32_t rnd(void) // LCG (numerical recipes); only the C side needs it, the inputs are in the file
{
	seed = seed * 1664525u + 1013904223u;
	return seed >> 8;
}
static uint32_t bits(float f)
{
	uint32_t u;
	memcpy(&u, &f, 4);
	return u;
}

static void run(const char *name, int numleafs, int maxnodes, int mode, int queries)
{
	bih_t bih;
	bih_leaf_t *leafs = (bih_leaf_t *)calloc(numleafs, sizeof(*leafs));
	bih_node_t *nodes = (bih_node_t *)calloc(maxnodes > 0 ? maxnodes : 1, sizeof(*nodes));
	int *sort = (int *)calloc(numleafs, sizeof(int));
	int *scratch = (int *)calloc(numleafs, sizeof(int));
	int i, j, error;
	printf("CASE\t%s\t%d\t%d\n", name, numleafs, maxnodes);
	for (i = 0; i < numleafs; i++)
	{
		bih_leaf_t *l = leafs + i;
		l->type = (bih_leaftype_t)(BIH_BRUSH + (int)(rnd() % 3));
		for (j = 0; j < 3; j++)
		{
			float c, e;
			if (mode == 1) // all leafs have the same bounds: no axis can split them
			{
				c = 16.0f * (float)j;
				e = 8.0f;
			}
			else if (mode == 2) // flat in x and y: only z splits
			{
				c = j == 2 ? (float)(int)(rnd() % 4096) * 0.125f - 256.0f : 3.5f;
				e = j == 2 ? (float)(int)(rnd() % 64) * 0.0625f : 1.0f;
			}
			else // general: fractional coordinates so float rounding matters
			{
				c = ((float)(int)(rnd() % 200000) - 100000.0f) / 37.0f;
				e = (float)(int)(rnd() % 3000) / 11.0f;
			}
			l->mins[j] = c - e;
			l->maxs[j] = c + e;
		}
		l->textureindex = (int)(rnd() % 50);
		l->surfaceindex = (int)(rnd() % 500);
		l->itemindex = i;
		printf("L\t%d\t%08x\t%08x\t%08x\t%08x\t%08x\t%08x\t%d\t%d\t%d\n", (int)l->type, bits(l->mins[0]), bits(l->mins[1]),
			bits(l->mins[2]), bits(l->maxs[0]), bits(l->maxs[1]), bits(l->maxs[2]), l->textureindex, l->surfaceindex, l->itemindex);
	}
	error = BIH_Build(&bih, numleafs, leafs, maxnodes, nodes, sort, scratch);
	printf("R\t%d\t%d\t%d\t%08x\t%08x\t%08x\t%08x\t%08x\t%08x\n", error, bih.numnodes, bih.rootnode, bits(bih.mins[0]),
		bits(bih.mins[1]), bits(bih.mins[2]), bits(bih.maxs[0]), bits(bih.maxs[1]), bits(bih.maxs[2]));
	for (i = 0; i < bih.numnodes; i++)
	{
		bih_node_t *n = nodes + i;
		printf("N\t%d\t%08x\t%08x\t%08x\t%08x\t%08x\t%08x\t%d\t%d\t%08x\t%08x", (int)n->type, bits(n->mins[0]), bits(n->mins[1]),
			bits(n->mins[2]), bits(n->maxs[0]), bits(n->maxs[1]), bits(n->maxs[2]), n->front, n->back, bits(n->frontmin), bits(n->backmax));
		for (j = 0; j < BIH_MAXUNORDEREDCHILDREN; j++)
			printf("\t%d", n->children[j]);
		printf("\n");
	}
	printf("S");
	for (i = 0; i < numleafs; i++)
		printf("\t%d", sort[i]);
	printf("\n");
	if (!error)
	{
		for (i = 0; i < queries; i++)
		{
			float mins[3], maxs[3];
			int idx[24], surf[24], n, max = i % 3 == 0 ? 4 : 24;
			for (j = 0; j < 3; j++)
			{
				float c = mode == 0 ? ((float)(int)(rnd() % 200000) - 100000.0f) / 41.0f : (float)(int)(rnd() % 600) * 0.5f - 280.0f;
				float e = (float)(int)(rnd() % 4000) / 7.0f;
				mins[j] = c - e;
				maxs[j] = c + e;
			}
			n = BIH_GetTriangleListForBox(&bih, max, idx, i % 2 ? surf : NULL, mins, maxs);
			printf("Q\t%08x\t%08x\t%08x\t%08x\t%08x\t%08x\t%d\t%d\t%d", bits(mins[0]), bits(mins[1]), bits(mins[2]), bits(maxs[0]),
				bits(maxs[1]), bits(maxs[2]), max, i % 2, n);
			for (j = 0; j < n && j < max; j++)
				printf("\t%d:%d", idx[j], i % 2 ? surf[j] : -1);
			printf("\n");
		}
	}
	free(leafs);
	free(nodes);
	free(sort);
	free(scratch);
}

int main(void)
{
	seed = 20261125u;
	run("one", 1, 1, 0, 4);
	run("eight", 8, 4, 0, 6);
	run("nine", 9, 9, 0, 6);
	run("fifty", 50, 50, 0, 12);
	run("general", 700, 700, 0, 40);
	run("samebounds", 40, 40, 1, 6);
	run("zonly", 120, 120, 2, 12);
	run("outofnodes", 300, 5, 0, 0);
	return 0;
}
