// Reference vectors for the line testing and linking part of engine/sv_phys.luau (SV_GetPitchSign ..
// SV_LinkEdict, SV_NudgeOutOfSolid) and SV_GetModelByIndex / SV_GetModelFromEdict of engine/sv_main.luau:
// the release's sv_phys.c, sv_main.c, world.c, collision.c, ... compiled unchanged (svphys_vectors.sh).
// trace_vectors.c is included as it is (its main renamed) for its synthetic map: the world model and a
// submodel with the real Mod_Q3BSP_Trace* functions of model_brush.c. On top of it a server is set up by
// hand: QuakeC field / global offsets, edict field memory, the area grid, sv.models (the world, the submodel
// and a copy of it typed as an alias model, for the pitch sign) and entities of every solid type. Every input
// and result goes to tests/vectors/svphys.tsv, floats as bit patterns, doubles as 64-bit patterns.
// All names here start with spv_ or SPV_ (trace_vectors.c uses tv_; sv_ would clash with engine cvars).
#define main tv_trace_main
#include "trace_vectors.c"
#undef main

// ---- what the linked code needs from the parts of the engine that are not linked
gamemode_t gamemode; // common.c; GAME_NORMAL (SV_GetPitchSign only tests it for GAME_TENEBRAE)
prvm_prog_t prvm_prog_list[PRVM_PROG_MAX]; // prvm_edict.c
prvm_eval_t prvm_badvalue; // prvm_edict.c (only read for a negative field offset)
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
// prvm_cmds.c: the Luau port passes a NULL frameblend / skeleton; the Q3BSP trace functions ignore both
void VM_GenerateFrameGroupBlend(prvm_prog_t *prog, framegroupblend_t *framegroupblend, const prvm_edict_t *ed)
{
	(void)prog; (void)framegroupblend; (void)ed;
}
void VM_FrameBlendFromFrameGroupBlend(frameblend_t *frameblend, const framegroupblend_t *framegroupblend, const dp_model_t *model, double curtime)
{
	(void)frameblend; (void)framegroupblend; (void)model; (void)curtime;
}
void VM_UpdateEdictSkeleton(prvm_prog_t *prog, prvm_edict_t *ed, const dp_model_t *edmodel, const frameblend_t *frameblend)
{
	(void)prog; (void)ed; (void)edmodel; (void)frameblend;
}

#define SPV_NED 160
#define SPV_NENT 120 // edicts 1 .. SPV_NENT are spawned and linked
#define SPV_NUDGE0 150 // edicts SPV_NUDGE0 .. SPV_NED-1 are used for SV_NudgeOutOfSolid (never linked)
#define SPV_NFIELDS 32
#define SPV_GLOBAL0 28
#define SPV_NGLOBALS 50
static prvm_edict_t spv_ed[SPV_NED];
static edict_engineprivate_t spv_priv[SPV_NED];
static prvm_vec_t spv_fields[SPV_NED * SPV_NFIELDS];
static prvm_vec_t spv_globals[SPV_NGLOBALS];
static float spv_target[SPV_NED][3]; // a point the entity's geometry is around (for aiming)
static dp_model_t spv_alias; // the submodel, typed mod_alias
static int spv_touchcount;

#define SPV_SETCV(v, x) do { (v).value = (float)(x); (v).integer = (int)(v).value; printf("CVAR\t%s\t%.9g\n", (v).name, (double)(v).value); } while (0)

static const char *spv_modeltag(const dp_model_t *m)
{
	if (!m)
		return "-";
	if (m == tv_model + 0)
		return "w";
	if (m == tv_model + 1)
		return "s";
	if (m == &spv_alias)
		return "a";
	return "?";
}
static int spv_num(const void *e) // edict number of a trace_t.ent / list entry, -1 for NULL
{
	return e ? (int)((const prvm_edict_t *)e - spv_ed) : -1;
}
static void spv_pd(double d)
{
	printf("\t%016llx", tv_dbits(d));
}

// prog->ExecuteProgram: the touch function calls of SV_LinkEdict_TouchAreaGrid_Call, with every global
static void spv_execute(prvm_prog_t *prog, func_t fnum, const char *errormessage)
{
	int i;
	(void)errormessage;
	spv_touchcount++;
	printf("TOUCH\t%d", (int)fnum);
	for (i = 0; i < SPV_NGLOBALS; i++)
		printf("\t%08x", (unsigned)prog->globals.ip[i]);
	printf("\n");
}

static void spv_setupprog(void)
{
	prvm_prog_t *prog = SVVM_prog;
	int ofs = 1, i; // field 0 is left unused, as in a real progs.dat
	memset(prog, 0, sizeof(*prog));
#define SPV_F(name, n) do { prog->fieldoffsets.name = ofs; printf("FIELD\t%s\t%d\n", #name, ofs); ofs += (n); } while (0)
	SPV_F(owner, 1);
	SPV_F(solid, 1);
	SPV_F(flags, 1);
	SPV_F(mins, 3);
	SPV_F(maxs, 3);
	SPV_F(origin, 3);
	SPV_F(angles, 3);
	SPV_F(modelindex, 1);
	SPV_F(dphitcontentsmask, 1);
	SPV_F(pflags, 1);
	SPV_F(movetype, 1);
	SPV_F(avelocity, 3);
	SPV_F(absmin, 3);
	SPV_F(absmax, 3);
	SPV_F(touch, 1);
	SPV_F(frame, 1);
	SPV_F(effects, 1);
#undef SPV_F
	printf("NFIELDS\t%d\n", SPV_NFIELDS);
	ofs = SPV_GLOBAL0;
#define SPV_G(name, n) do { prog->globaloffsets.name = ofs; printf("GLOBAL\t%s\t%d\n", #name, ofs); ofs += (n); } while (0)
	SPV_G(self, 1);
	SPV_G(other, 1);
	SPV_G(time, 1);
	SPV_G(trace_allsolid, 1);
	SPV_G(trace_startsolid, 1);
	SPV_G(trace_fraction, 1);
	SPV_G(trace_inwater, 1);
	SPV_G(trace_inopen, 1);
	SPV_G(trace_endpos, 3);
	SPV_G(trace_plane_normal, 3);
	SPV_G(trace_plane_dist, 1);
	SPV_G(trace_ent, 1);
	SPV_G(trace_dpstartcontents, 1);
	SPV_G(trace_dphitcontents, 1);
	SPV_G(trace_dphitq3surfaceflags, 1);
	SPV_G(trace_dphittexturename, 1);
#undef SPV_G
	printf("NGLOBALS\t%d\n", SPV_NGLOBALS);
	prog->entityfields = SPV_NFIELDS;
	prog->entityfieldsarea = SPV_NFIELDS * SPV_NED;
	prog->edictsfields = spv_fields;
	prog->edicts = spv_ed;
	prog->max_edicts = SPV_NED;
	prog->num_edicts = SPV_NED;
	prog->limit_edicts = SPV_NED;
	prog->globals.fp = spv_globals;
	prog->name = "server";
	prog->ExecuteProgram = spv_execute;
	for (i = 0; i < SPV_NED; i++)
	{
		spv_ed[i].priv.server = spv_priv + i;
		spv_ed[i].fields.fp = spv_fields + i * SPV_NFIELDS;
	}
	printf("NED\t%d\n", SPV_NED);
}

// the bounds Mod_Q3BSP_Load would give a model (normal box over its brushes and surfaces, yaw / rotated radius)
static void spv_setbounds(dp_model_t *m)
{
	int i, j, first = 1;
	float mins[3] = {0, 0, 0}, maxs[3] = {0, 0, 0}, corner[3], yr, r;
	for (i = m->firstmodelbrush; i < m->firstmodelbrush + m->nummodelbrushes; i++)
	{
		const colbrushf_t *b = tv_brush[i].colbrushf;
		if (!b)
			continue;
		for (j = 0; j < 3; j++)
		{
			mins[j] = first ? b->mins[j] : min(mins[j], b->mins[j]);
			maxs[j] = first ? b->maxs[j] : max(maxs[j], b->maxs[j]);
		}
		first = 0;
	}
	for (i = m->firstmodelsurface; i < m->firstmodelsurface + m->nummodelsurfaces; i++)
	{
		for (j = 0; j < 3; j++)
		{
			mins[j] = min(mins[j], tv_surf[i].mins[j]);
			maxs[j] = max(maxs[j], tv_surf[i].maxs[j]);
		}
	}
	for (j = 0; j < 3; j++)
		corner[j] = max(fabs(mins[j]), fabs(maxs[j]));
	yr = (float)sqrt(corner[0] * corner[0] + corner[1] * corner[1]);
	r = (float)sqrt(corner[0] * corner[0] + corner[1] * corner[1] + corner[2] * corner[2]);
	VectorCopy(mins, m->normalmins);
	VectorCopy(maxs, m->normalmaxs);
	m->yawmins[0] = m->yawmins[1] = -yr;
	m->yawmaxs[0] = m->yawmaxs[1] = yr;
	m->yawmins[2] = mins[2];
	m->yawmaxs[2] = maxs[2];
	VectorSet(m->rotatedmins, -r, -r, -r);
	VectorSet(m->rotatedmaxs, r, r, r);
}
static void spv_printmodel(int idx, int src)
{
	const dp_model_t *m = sv.models[idx];
	printf("SMODEL\t%d\t%d\t%s\t%d", idx, src, m->type == mod_alias ? "alias" : "brushq3", m->numframes);
	tv_pv(m->normalmins);
	tv_pv(m->normalmaxs);
	tv_pv(m->yawmins);
	tv_pv(m->yawmaxs);
	tv_pv(m->rotatedmins);
	tv_pv(m->rotatedmaxs);
	printf("\n");
}
static void spv_setupserver(void)
{
	static const float wmins[3] = {-2048, -2048, -1024}, wmaxs[3] = {2048, 2048, 1024};
	int i;
	memset(&sv, 0, sizeof(sv));
	tv_model[0].type = mod_brushq3;
	tv_model[0].numframes = 1;
	tv_model[1].type = mod_brushq3;
	tv_model[1].numframes = 1;
	spv_setbounds(tv_model + 0);
	spv_setbounds(tv_model + 1);
	spv_alias = tv_model[1];
	spv_alias.type = mod_alias;
	spv_alias.numframes = 3;
	sv.worldmodel = tv_model + 0;
	sv.models[1] = tv_model + 0;
	sv.models[2] = tv_model + 1;
	sv.models[3] = &spv_alias;
	spv_printmodel(1, 0);
	spv_printmodel(2, 1);
	spv_printmodel(3, 1);
	sv.time = 1234.56789012345;
	printf("TIME");
	spv_pd(sv.time);
	printf("\n");
	World_SetSize(&sv.world, "maps/svphys.bsp", wmins, wmaxs, SVVM_prog);
	printf("WORLD");
	tv_pv(wmins);
	tv_pv(wmaxs);
	printf("\nG");
	tv_pv(sv.world.areagrid_mins);
	tv_pv(sv.world.areagrid_maxs);
	tv_pv(sv.world.areagrid_size);
	tv_pv(sv.world.areagrid_bias);
	tv_pv(sv.world.areagrid_scale);
	printf("\n");
	for (i = 0; i < SPV_NGLOBALS; i++)
		spv_globals[i] = 0;
}

// ---- entities
static void spv_printed(int n)
{
	int i;
	uint32_t u;
	printf("ED\t%d\t%d", n, (int)spv_priv[n].free);
	for (i = 0; i < SPV_NFIELDS; i++)
	{
		memcpy(&u, spv_fields + n * SPV_NFIELDS + i, 4);
		printf("\t%08x", u);
	}
	printf("\n");
}
static void spv_setfree(int n, int f)
{
	spv_priv[n].free = f;
	printf("F\t%d\t%d\n", n, f);
}
static void spv_randsize(float *mins, float *maxs)
{
	int j, r = (int)(tv_rnd() % 20);
	if (r < 3)
	{
		VectorClear(mins);
		VectorClear(maxs);
	}
	else if (r < 5) // a point that is not at the origin
	{
		for (j = 0; j < 3; j++)
			mins[j] = maxs[j] = tv_frand(-8, 8);
	}
	else if (r < 10)
	{
		VectorSet(mins, -16, -16, -24);
		VectorSet(maxs, 16, 16, 45);
	}
	else if (r < 19)
	{
		for (j = 0; j < 3; j++)
		{
			mins[j] = -tv_frand(1, 48);
			maxs[j] = tv_frand(1, 48);
		}
	}
	else // large: linked outside the area grid
	{
		for (j = 0; j < 3; j++)
		{
			mins[j] = -tv_frand(100, 900);
			maxs[j] = tv_frand(100, 900);
		}
	}
}
static void spv_makeent(int n)
{
	static const int masks[6] = {1, 0x21, 0x2000001, 3, 0x121, 0x61};
	static const float pflagvals[5] = {128, 129, 384, 256, 127};
	prvm_prog_t *prog = SVVM_prog;
	prvm_edict_t *ed = spv_ed + n;
	float solid, *o, *a, off[3], *mins, *maxs;
	int r, j, modelindex, bsp;
	matrix4x4_t m;
	static const float x800[3] = {800, 0, 0};
	memset(ed->fields.fp, 0, sizeof(prvm_vec_t) * SPV_NFIELDS);
	r = (int)(tv_rnd() % 100);
	solid = r < 8 ? SOLID_NOT : r < 22 ? SOLID_TRIGGER : r < 40 ? SOLID_BBOX : r < 62 ? SOLID_SLIDEBOX : r < 84 ? SOLID_BSP : r < 96 ? SOLID_CORPSE : r < 98 ? 4.5f : 2.5f;
	PRVM_serveredictfloat(ed, solid) = solid;
	bsp = (int)solid == SOLID_BSP;
	r = (int)(tv_rnd() % 100);
	if (bsp)
		modelindex = r < 55 ? 2 : r < 75 ? 3 : r < 82 ? 0 : r < 87 ? 4 : r < 92 ? 1 : r < 96 ? -2 : 9000;
	else
		modelindex = r < 75 ? 0 : r < 90 ? 3 : 2;
	PRVM_serveredictfloat(ed, modelindex) = modelindex;
	r = (int)(tv_rnd() % 10);
	PRVM_serveredictfloat(ed, flags) = r < 5 ? 0 : r < 7 ? FL_MONSTER : r < 8 ? FL_ITEM : r < 9 ? (FL_MONSTER | FL_ITEM) : 4097;
	PRVM_serveredictedict(ed, owner) = (tv_rnd() % 10) < 7 ? 0 : 1 + (int)(tv_rnd() % (SPV_NED - 1));
	PRVM_serveredictfloat(ed, dphitcontentsmask) = (tv_rnd() % 4) ? 0 : masks[tv_rnd() % 6];
	PRVM_serveredictfloat(ed, pflags) = (tv_rnd() % 10) < 7 ? 0 : pflagvals[tv_rnd() % 5];
	r = (int)(tv_rnd() % 8);
	PRVM_serveredictfloat(ed, frame) = r < 6 ? (float)(r % 4) : r == 6 ? -2 : 7;
	r = (int)(tv_rnd() % 10);
	if ((int)solid == SOLID_TRIGGER ? r < 8 : r < 2)
		PRVM_serveredictfunction(ed, touch) = 1 + (int)(tv_rnd() % 50);
	PRVM_serveredictfloat(ed, movetype) = (tv_rnd() % 100) < 85 ? (float)(tv_rnd() % 11) : MOVETYPE_PHYSICS;
	a = PRVM_serveredictvector(ed, angles);
	r = (int)(tv_rnd() % 20);
	if (r < 7 && !bsp)
		VectorClear(a);
	else if (r < 7)
		VectorClear(a);
	else if (r < 13)
		VectorSet(a, 0, tv_frand(-180, 180), 0);
	else if (r < 17)
		VectorSet(a, tv_frand(-60, 60), tv_frand(-180, 180), tv_frand(-45, 45));
	else
		VectorSet(a, tv_frand(-60, 60), 0, 0);
	r = (int)(tv_rnd() % 10);
	if (r == 8)
		VectorSet(PRVM_serveredictvector(ed, avelocity), 0, tv_frand(-90, 90), 0);
	else if (r == 9)
		VectorSet(PRVM_serveredictvector(ed, avelocity), tv_frand(-90, 90), 0, 0);
	o = PRVM_serveredictvector(ed, origin);
	mins = PRVM_serveredictvector(ed, mins);
	maxs = PRVM_serveredictvector(ed, maxs);
	for (j = 0; j < 3; j++)
		spv_target[n][j] = tv_frand(-380, 380);
	if (bsp && (modelindex == 2 || modelindex == 3))
	{
		// put the submodel's geometry (around 800 0 0 in model space) around the target point
		Matrix4x4_CreateFromQuakeEntity(&m, 0, 0, 0, (modelindex == 3 ? -1 : 1) * a[0], a[1], a[2], 1);
		Matrix4x4_Transform(&m, x800, off);
		VectorSubtract(spv_target[n], off, o);
		if (tv_rnd() % 5)
		{
			VectorCopy(tv_model[1].normalmins, mins);
			VectorCopy(tv_model[1].normalmaxs, maxs);
		}
	}
	else
	{
		VectorCopy(spv_target[n], o);
		spv_randsize(mins, maxs);
	}
}
static void spv_link(int n)
{
	prvm_prog_t *prog = SVVM_prog;
	printf("LINK\t%d\n", n);
	SV_LinkEdict(spv_ed + n);
	printf("LK\t%d", n);
	tv_pv(PRVM_serveredictvector(spv_ed + n, absmin));
	tv_pv(PRVM_serveredictvector(spv_ed + n, absmax));
	printf("\n");
}
static void spv_touchgrid(int n)
{
	prvm_prog_t *prog = SVVM_prog;
	int s = (int)(tv_rnd() % SPV_NED), o = (int)(tv_rnd() % SPV_NED);
	PRVM_serverglobaledict(self) = s;
	PRVM_serverglobaledict(other) = o;
	printf("TG\t%d\t%d\t%d\n", n, s, o);
	spv_touchcount = 0;
	SV_LinkEdict_TouchAreaGrid(spv_ed + n);
	printf("TGEND\t%d\t%d\t%d\n", spv_touchcount, PRVM_serverglobaledict(self), PRVM_serverglobaledict(other));
}
static void spv_touchcall(int touch, int ent)
{
	prvm_prog_t *prog = SVVM_prog;
	printf("TC\t%d\t%d\n", touch, ent);
	spv_touchcount = 0;
	SV_LinkEdict_TouchAreaGrid_Call(spv_ed + touch, spv_ed + ent);
	printf("TGEND\t%d\t%d\t%d\n", spv_touchcount, PRVM_serverglobaledict(self), PRVM_serverglobaledict(other));
}
static void spv_query(int n) // SV_GenericHitSuperContentsMask, SV_GetPitchSign, SV_GetModelFromEdict
{
	prvm_prog_t *prog = SVVM_prog;
	if (n < 0)
	{
		printf("EQ\t-1\t%d\t0\t%s\n", SV_GenericHitSuperContentsMask(NULL), spv_modeltag(SV_GetModelFromEdict(NULL)));
		return;
	}
	printf("EQ\t%d\t%d\t%d\t%s\n", n, SV_GenericHitSuperContentsMask(spv_ed + n), SV_GetPitchSign(prog, spv_ed + n), spv_modeltag(SV_GetModelFromEdict(spv_ed + n)));
}

// ---- traces
static int spv_pickent(int wantsolid) // a spawned entity that is not free (mostly)
{
	prvm_prog_t *prog = SVVM_prog;
	int i, n = 1;
	for (i = 0; i < 40; i++)
	{
		n = 1 + (int)(tv_rnd() % SPV_NENT);
		if (!spv_priv[n].free && (!wantsolid || PRVM_serveredictfloat(spv_ed + n, solid) >= SOLID_BBOX))
			return n;
	}
	return n;
}
static void spv_aim(float *start, float *end)
{
	float c[3], dir[3], a, b;
	int j, n, mode;
	if (tv_rnd() % 5 < 3)
	{
		n = spv_pickent(1);
		for (j = 0; j < 3; j++)
			c[j] = spv_target[n][j] + tv_frand(-24, 24);
		tv_randnormal(dir);
		mode = (int)(tv_rnd() % 6);
		if (mode < 4)
		{
			a = tv_frand(40, 400);
			b = tv_frand(0, 200);
			for (j = 0; j < 3; j++)
			{
				start[j] = c[j] + dir[j] * a;
				end[j] = c[j] - dir[j] * b;
			}
		}
		else if (mode == 4) // starts inside
		{
			a = tv_frand(1, 200);
			for (j = 0; j < 3; j++)
			{
				start[j] = c[j];
				end[j] = c[j] + dir[j] * a;
			}
		}
		else // does not move
		{
			a = tv_frand(0, 30);
			for (j = 0; j < 3; j++)
				start[j] = end[j] = c[j] + dir[j] * a;
		}
	}
	else
		tv_aim(0, start, end, 0);
}
static prvm_edict_t *spv_passedict(void)
{
	prvm_prog_t *prog = SVVM_prog;
	int i, n, r = (int)(tv_rnd() % 6);
	if (r == 0)
		return NULL;
	if (r == 1)
		return spv_ed;
	if (r < 4)
		return spv_ed + spv_pickent(0);
	for (i = 0; i < 60; i++) // an owned entity, or its owner
	{
		n = 1 + (int)(tv_rnd() % SPV_NENT);
		if (PRVM_serveredictedict(spv_ed + n, owner))
			return r == 4 ? spv_ed + n : spv_ed + PRVM_serveredictedict(spv_ed + n, owner);
	}
	return spv_ed + 1;
}
static void spv_masks(prvm_edict_t *pass, int *hit, int *skip, int *mat, float *extend)
{
	static const int hits[10] = {1, 0x21, 0x61, 0x121, 0x221, 0x41, 0x20, 3, 0x1001, 0x2000021};
	static const int skips[6] = {0, 0, 0, 0x20, 1, 0x100};
	static const int mats[5] = {0, 0, 0, 0x10, 1};
	static const float extends[4] = {0, 16, 1, 0.03125f};
	*hit = (tv_rnd() % 5) < 2 ? SV_GenericHitSuperContentsMask(pass) : hits[tv_rnd() % 10];
	*skip = skips[tv_rnd() % 6];
	*mat = mats[tv_rnd() % 5];
	*extend = extends[tv_rnd() % 4];
}
static void spv_result(const trace_t *t)
{
	printf("R\t%d\t%d\t%d\t%d\t%d\t%d", t->allsolid, t->startsolid, t->worldstartsolid, t->bmodelstartsolid, t->inopen, t->inwater);
	spv_pd(t->fraction);
	spv_pd(t->endpos[0]);
	spv_pd(t->endpos[1]);
	spv_pd(t->endpos[2]);
	tv_pv(t->plane.normal);
	tv_pf(t->plane.dist);
	printf("\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d", spv_num(t->ent), t->hitsupercontentsmask, t->skipsupercontentsmask, t->skipmaterialflagsmask,
		t->startsupercontents, t->hitsupercontents, t->hitq3surfaceflags, tv_texidx(t->hittexture), t->startfound);
	spv_pd(t->startdepth);
	spv_pd(t->startdepthnormal[0]);
	spv_pd(t->startdepthnormal[1]);
	spv_pd(t->startdepthnormal[2]);
	printf("\t%d\n", tv_texidx(t->starttexture));
}
static void spv_trace(int kind) // 0: SV_TraceBox, 1: SV_TraceLine, 2: SV_TracePoint
{
	float start[3], end[3], mins[3], maxs[3], extend;
	int hit, skip, mat, type, j, r;
	prvm_edict_t *pass;
	trace_t t;
	spv_aim(start, end);
	r = (int)(tv_rnd() % 20);
	type = r < 19 ? r % 5 : 5; // MOVE_NORMAL .. MOVE_HITMODEL, rarely an unknown type
	pass = spv_passedict();
	spv_masks(pass, &hit, &skip, &mat, &extend);
	if (kind == 0)
	{
		r = (int)(tv_rnd() % 10);
		if (r == 0)
		{
			VectorClear(mins);
			VectorClear(maxs);
		}
		else if (r == 1) // mins == maxs, not at the origin: shifted line / point trace
		{
			for (j = 0; j < 3; j++)
				mins[j] = maxs[j] = tv_frand(-10, 10);
		}
		else if (r < 5)
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
		printf("TB\t%d\t%d\t%d\t%d\t%d", type, spv_num(pass), hit, skip, mat);
		tv_pv(start);
		tv_pv(mins);
		tv_pv(maxs);
		tv_pv(end);
		tv_pf(extend);
		printf("\n");
		t = SV_TraceBox(start, mins, maxs, end, type, pass, hit, skip, mat, extend);
	}
	else if (kind == 1)
	{
		printf("TL\t%d\t%d\t%d\t%d\t%d", type, spv_num(pass), hit, skip, mat);
		tv_pv(start);
		tv_pv(end);
		tv_pf(extend);
		printf("\n");
		t = SV_TraceLine(start, end, type, pass, hit, skip, mat, extend);
	}
	else
	{
		printf("TP\t%d\t%d\t%d\t%d\t%d", type, spv_num(pass), hit, skip, mat);
		tv_pv(start);
		printf("\n");
		t = SV_TracePoint(start, type, pass, hit, skip, mat);
	}
	spv_result(&t);
}
static void spv_traces(int nbox, int nline, int npoint)
{
	int i;
	for (i = 0; i < nbox + nline + npoint; i++)
		spv_trace(i < nbox ? 0 : i < nbox + nline ? 1 : 2);
}
static void spv_pointcontents(void)
{
	float p[3];
	int j, r = (int)(tv_rnd() % 10), n;
	if (r < 5)
	{
		n = spv_pickent(1);
		for (j = 0; j < 3; j++)
			p[j] = spv_target[n][j] + tv_frand(-60, 60);
	}
	else if (r < 8)
	{
		n = tv_pickbrush(0);
		for (j = 0; j < 3; j++)
			p[j] = tv_bcenter[n][j] + tv_frand(-60, 60);
	}
	else
	{
		for (j = 0; j < 3; j++)
			p[j] = tv_frand(-500, 500);
	}
	printf("PC");
	tv_pv(p);
	printf("\t%d\n", SV_PointSuperContents(p));
}
static void spv_entitiesinbox(void)
{
	static const int maxes[6] = {512, 512, 512, 3, 1, 0};
	static prvm_edict_t *list[512];
	float mins[3], maxs[3], c, e;
	int j, n, maxedicts = maxes[tv_rnd() % 6], isnull = (tv_rnd() % 12) == 0, big = (int)(tv_rnd() % 4), pick = spv_pickent(0);
	for (j = 0; j < 3; j++)
	{
		c = (tv_rnd() % 2) ? spv_target[pick][j] : tv_frand(-600, 600);
		e = big == 0 ? tv_frand(400, 1500) : tv_frand(0, 80);
		mins[j] = c - e;
		maxs[j] = c + tv_frand(0, e);
	}
	n = SV_EntitiesInBox(mins, maxs, maxedicts, isnull ? NULL : list);
	printf("EB");
	tv_pv(mins);
	tv_pv(maxs);
	printf("\t%d\t%d\t%d", maxedicts, isnull, n);
	for (j = 0; j < n && j < maxedicts && !isnull; j++)
		printf("\t%d", spv_num(list[j]));
	printf("\n");
}
// an entity stuck in (or near) a world brush or a bmodel entity, nudged out
static void spv_nudge(void)
{
	prvm_prog_t *prog = SVVM_prog;
	int n = SPV_NUDGE0 + (int)(tv_rnd() % (SPV_NED - SPV_NUDGE0)), j, b, r = (int)(tv_rnd() % 10), ok;
	prvm_edict_t *ed = spv_ed + n;
	float c[3], dir[3], a;
	memset(ed->fields.fp, 0, sizeof(prvm_vec_t) * SPV_NFIELDS);
	if (r < 6)
	{
		b = tv_pickbrush(0);
		VectorCopy(tv_bcenter[b], c);
	}
	else
	{
		b = spv_pickent(1);
		VectorCopy(spv_target[b], c);
	}
	tv_randnormal(dir);
	a = tv_frand(0, 100);
	for (j = 0; j < 3; j++)
		PRVM_serveredictvector(ed, origin)[j] = c[j] + dir[j] * a;
	PRVM_serveredictfloat(ed, solid) = (tv_rnd() % 4) ? SOLID_SLIDEBOX : SOLID_BBOX;
	PRVM_serveredictfloat(ed, flags) = (tv_rnd() % 4) ? 0 : FL_MONSTER;
	spv_randsize(PRVM_serveredictvector(ed, mins), PRVM_serveredictvector(ed, maxs));
	spv_printed(n);
	ok = SV_NudgeOutOfSolid(ed);
	printf("NU\t%d\t%d", n, ok);
	tv_pv(PRVM_serveredictvector(ed, origin));
	printf("\n");
}
static void spv_relinkall(void)
{
	int n;
	for (n = 0; n <= SPV_NENT; n++)
		spv_link(n);
}

int main(void)
{
	prvm_prog_t *prog = SVVM_prog;
	static const int modelidx[10] = {-1, 0, 1, 2, 3, 4, 5, 8191, 8192, 9000};
	int i, n;
	setvbuf(stdout, NULL, _IOLBF, 0); // a crash keeps every finished line (the workflow log shows the last ones)
	tv_seed = 20261129u;

	// what Collision_Init / Mod_BrushInit / SV_Init would have set by registering the cvars
	collision_impactnudge.value = 0.03125f;
	collision_triangle_axialsides.integer = 1;
	mod_q3bsp_curves_collisions.integer = 1;
	mod_q3bsp_optimizedtraceline.integer = 1;
	mod_collision_bih.integer = 1;
	SPV_SETCV(collision_extendmovelength, 16);
	SPV_SETCV(sv_areagrid_mingridsize, 128);
	SPV_SETCV(sv_debugmove, 0);
	SPV_SETCV(sv_areadebug, 0);
	SPV_SETCV(sv_gameplayfix_swiminbmodels, 1);
	SPV_SETCV(sv_legacy_bbox_expand, 1);
	SPV_SETCV(sv_gameplayfix_nudgeoutofsolid_separation, 0.03125f);

	tv_maketextures();
	tv_makebrushes();
	tv_makesurfaces();
	tv_makebsp();
	tv_makemodels();
	spv_setupprog();
	spv_setupserver();

	// spawn and link; some are free before they are linked (SV_LinkEdict does nothing for them)
	for (n = 1; n <= SPV_NENT; n++)
	{
		spv_makeent(n);
		spv_priv[n].free = (tv_rnd() % 25) == 0;
		spv_printed(n);
	}
	spv_relinkall();
	// touch functions of the triggers each entity is in
	for (n = 0; n <= SPV_NENT; n++)
		spv_touchgrid(n);
	for (i = 0; i < 12; i++)
		spv_touchcall(1 + (int)(tv_rnd() % SPV_NENT), (int)(tv_rnd() % SPV_NED));
	for (n = 0; n < SPV_NED; n++)
		spv_query(n);
	spv_query(-1);
	for (i = 0; i < 10; i++)
		printf("GM\t%d\t%s\n", modelidx[i], spv_modeltag(SV_GetModelByIndex(modelidx[i])));

	spv_traces(220, 160, 100);
	for (i = 0; i < 80; i++)
		spv_pointcontents();
	for (i = 0; i < 60; i++)
		spv_entitiesinbox();
	for (i = 0; i < 40; i++)
		spv_nudge();

	// mod_collision_bih 0: the BSP tree / brush list paths of the models
	TV_SETCV(mod_collision_bih, 0);
	spv_traces(30, 30, 20);
	TV_SETCV(mod_collision_bih, 1);

	// cvar variants
	SPV_SETCV(sv_debugmove, 1);
	spv_traces(30, 30, 20);
	SPV_SETCV(sv_debugmove, 0);

	SPV_SETCV(sv_areadebug, 1);
	for (i = 0; i < 30; i++)
		spv_entitiesinbox();
	spv_traces(30, 20, 20);
	for (i = 0; i < 20; i++)
		spv_touchgrid(1 + (int)(tv_rnd() % SPV_NENT));
	for (i = 0; i < 10; i++)
		spv_pointcontents();
	SPV_SETCV(sv_areadebug, 0);

	SPV_SETCV(sv_gameplayfix_swiminbmodels, 0);
	for (i = 0; i < 30; i++)
		spv_pointcontents();
	SPV_SETCV(sv_gameplayfix_swiminbmodels, 1);

	SPV_SETCV(sv_gameplayfix_nudgeoutofsolid_separation, 0);
	for (i = 0; i < 15; i++)
		spv_nudge();
	SPV_SETCV(sv_gameplayfix_nudgeoutofsolid_separation, 0.5f);
	for (i = 0; i < 15; i++)
		spv_nudge();
	SPV_SETCV(sv_gameplayfix_nudgeoutofsolid_separation, 0.03125f);
	SPV_SETCV(collision_extendmovelength, 0);
	for (i = 0; i < 10; i++)
		spv_nudge();
	SPV_SETCV(collision_extendmovelength, 16);

	SPV_SETCV(sv_legacy_bbox_expand, 0);
	spv_relinkall();
	for (i = 0; i < 20; i++)
		spv_touchgrid(1 + (int)(tv_rnd() % SPV_NENT));
	spv_traces(30, 20, 10);
	for (i = 0; i < 20; i++)
		spv_entitiesinbox();
	SPV_SETCV(sv_legacy_bbox_expand, 1);
	spv_relinkall();

	// freed while linked: they stay in the area grid and are skipped
	for (i = 0; i < 10; i++)
		spv_setfree(1 + (int)(tv_rnd() % SPV_NENT), 1);
	for (n = 0; n < SPV_NED; n++)
		spv_query(n);
	spv_traces(40, 30, 20);
	for (i = 0; i < 20; i++)
		spv_entitiesinbox();
	for (i = 0; i < 20; i++)
		spv_touchgrid(1 + (int)(tv_rnd() % SPV_NENT));
	(void)prog;
	printf("END\n");
	return 0;
}
