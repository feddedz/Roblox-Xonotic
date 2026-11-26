// Reference vectors for the movers half of engine/sv_phys.luau (sv_phys.c L893-3232: SV_TestEntityPosition ..
// SV_Physics) and its AngleVectorsFLU (mathlib.c L498-550). The release's sv_phys.c is compiled INTO this file
// (#include, so its static functions can be called one at a time) and linked with sv_main.c, world.c, collision.c,
// polygon.c, bih.c, mathlib.c and matrixlib.c, all unchanged (movers_vectors.sh).
// trace_vectors.c is included as it is (its main renamed) for its synthetic map. On top of it a server is set up by
// hand as svphys_vectors.c does it (that file's own main would clash with this one, so its few setup helpers are
// repeated here with the mv_ prefix): QuakeC field / global / function offsets, edict memory, sv.models, the area
// grid, the cvars at their registered values (then the values Xonotic's own configs give them), two client slots
// and a scene east of the world model (box entities: floor, walls, a corner, steps, stairs, a ledge, a low
// ceiling; a static and a rotated bmodel). prog->ExecuteProgram prints every QC call with the globals the engine
// set and applies a small effect chosen by the function number (mv_effect; the Luau test does the same).
// Every call prints its arguments, the QC calls it made, every edict field word / global / private edict value /
// client value it changed and its result; floats as bit patterns, doubles as 64-bit patterns.
// All names here start with mv_ or MV_ (trace_vectors.c uses tv_; sv_ would clash with engine cvars).
#define main tv_trace_main
#include "trace_vectors.c"
#undef main
#include "sv_phys.c"

// ---- what the code needs from the parts of the engine that are not linked
gamemode_t gamemode; // common.c; GAME_NORMAL (SV_GetPitchSign only tests it for GAME_TENEBRAE)
prvm_prog_t prvm_prog_list[PRVM_PROG_MAX]; // prvm_edict.c
prvm_eval_t prvm_badvalue; // prvm_edict.c (only read for a negative field offset)
client_t *host_client; // host.c
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
// prvm_edict.c: no strings are loaded (classname is 0); a temp string is "some nonzero number" (the test only
// compares trace_dphittexturename with zero)
const char *PRVM_GetString(prvm_prog_t *prog, int num)
{
	(void)prog; (void)num;
	return "";
}
int PRVM_SetTempString(prvm_prog_t *prog, const char *s)
{
	(void)prog;
	return s ? 1 : 0;
}
unsigned int PRVM_EDICT_NUM_ERROR(prvm_prog_t *prog, unsigned int n, const char *filename, int fileline)
{
	(void)prog;
	printf("EDICTNUMERROR\t%u\t%s\t%d\n", n, filename, fileline);
	exit(1);
}
// prvm_edict.c PRVM_ED_CanAlloc with realtime == prvm_reuseedicts_always_allow == 0 (the state the Luau test runs
// the real function in): a free edict can always be reused
qboolean PRVM_ED_CanAlloc(prvm_prog_t *prog, prvm_edict_t *e)
{
	(void)prog;
	return e->priv.required->free ? true : false;
}
// prvm_cmds.c L5998-6013 VM_SetTraceGlobals, copied unchanged (prvm_cmds.c is not linked)
void VM_SetTraceGlobals(prvm_prog_t *prog, const trace_t *trace)
{
	PRVM_gameglobalfloat(trace_allsolid) = trace->allsolid;
	PRVM_gameglobalfloat(trace_startsolid) = trace->startsolid;
	PRVM_gameglobalfloat(trace_fraction) = trace->fraction;
	PRVM_gameglobalfloat(trace_inwater) = trace->inwater;
	PRVM_gameglobalfloat(trace_inopen) = trace->inopen;
	VectorCopy(trace->endpos, PRVM_gameglobalvector(trace_endpos));
	VectorCopy(trace->plane.normal, PRVM_gameglobalvector(trace_plane_normal));
	PRVM_gameglobalfloat(trace_plane_dist) = trace->plane.dist;
	PRVM_gameglobaledict(trace_ent) = PRVM_EDICT_TO_PROG(trace->ent ? trace->ent : prog->edicts);
	PRVM_gameglobalfloat(trace_dpstartcontents) = trace->startsupercontents;
	PRVM_gameglobalfloat(trace_dphitcontents) = trace->hitsupercontents;
	PRVM_gameglobalfloat(trace_dphitq3surfaceflags) = trace->hitq3surfaceflags;
	PRVM_gameglobalstring(trace_dphittexturename) = trace->hittexture ? PRVM_SetTempString(prog, trace->hittexture->name) : 0;
}
// sv_user.c is not linked (the Luau port logs NOT YET PORTED there; the test skips these lines). SV_StartSound is
// sv_main.c's own: with Xonotic's empty sv_sound_land / sv_sound_watersplash (set in main) SV_SoundIndex finds no
// sound and it returns before writing anything (the Luau port logs NOT YET PORTED)
static int mv_clientthinkcount;
void SV_ClientThink(void)
{
	mv_clientthinkcount++;
	printf("CLIENTTHINK\n");
}

// ---- the server prog
#define MV_NED 128
#define MV_NF 64
#define MV_G0 28
#define MV_NG 52
#define MV_SCENE0 3 // edicts 3 .. 18: the scene boxes, 19: static bmodel, 20: rotated bmodel
#define MV_BSP 19
#define MV_RBSP 20
#define MV_DYN0 21 // edicts 21 .. 126: entities of the cases
#define MV_SENT 127 // stays in use (a MOVETYPE_NONE SOLID_NOT entity) except in one frame sequence
#define MV_FN_START 1
#define MV_FN_END 2
#define MV_FN_PRE 3
#define MV_FN_POST 4
static prvm_edict_t mv_ed[MV_NED];
static edict_engineprivate_t mv_priv[MV_NED];
static prvm_vec_t mv_fields[MV_NED * MV_NF];
static prvm_vec_t mv_globals[MV_NG];
static client_t mv_clients[2];
static int mv_qcslots[40], mv_nqcslots;

#define MV_SETCV(v, x) do { (v).value = (float)(x); (v).integer = (int)(v).value; printf("CVAR\t%s\t%.9g\n", (v).name, (double)(v).value); } while (0)

static int mv_rn(int n)
{
	return (int)(tv_rnd() % (uint32_t)n);
}
static void mv_pd(double d)
{
	printf("\t%016llx", tv_dbits(d));
}

// ---- counts of what the cases reached (printed at the end)
static int mv_qcthink, mv_qctouch, mv_qcblocked, mv_qctransition, mv_qcland, mv_qcframe, mv_qcother;
static int mv_flyblocked[16], mv_flystep, mv_pefalse, mv_peworldstuck, mv_pmblocked, mv_pmmoved, mv_teleports;
static int mv_unstick[3], mv_waterlevels[4], mv_wmup, mv_wmdown, mv_wmrevert, mv_tosslanded, mv_tossbounced;
static int mv_calls[40];

// the effect of a QC function, by its number (the Luau test applies the same ones)
static void mv_effect(prvm_prog_t *prog, int fnum)
{
	int i, self = PRVM_serverglobaledict(self), other = PRVM_serverglobaledict(other);
	prvm_edict_t *s = mv_ed + self, *o = mv_ed + other;
	float time = PRVM_serverglobalfloat(time);
	if (fnum == MV_FN_PRE)
	{
		PRVM_serveredictvector(s, velocity)[0] += 5;
		return;
	}
	if (fnum == MV_FN_POST)
	{
		PRVM_serveredictfloat(s, fixangle) = 1;
		return;
	}
	if (fnum < 10)
		return;
	switch (fnum % 10)
	{
	case 0: // spawn(): the first free edict of the cases is in use again, not moved yet
		for (i = MV_DYN0; i < MV_SENT; i++)
		{
			if (mv_priv[i].free)
			{
				mv_priv[i].free = false;
				mv_priv[i].move = false;
				break;
			}
		}
		break;
	case 1:
		PRVM_serveredictfloat(s, nextthink) = time + 0.05f;
		break;
	case 2:
		PRVM_serveredictfloat(s, nextthink) = time;
		break;
	case 3:
		PRVM_serveredictvector(s, velocity)[2] += 100;
		break;
	case 4: // remove(self)
		if (self > 2 && self < MV_NED - 1)
			mv_priv[self].free = true;
		break;
	case 5: // setorigin(self, self.origin + '0 0 64') as VM_SV_setorigin does it
		if (self > 0)
		{
			PRVM_serveredictvector(s, origin)[2] += 64;
			if (mv_priv[self].mark == PRVM_EDICT_MARK_WAIT_FOR_SETORIGIN)
			{
				mv_priv[self].mark = PRVM_EDICT_MARK_SETORIGIN_CAUGHT;
				mv_teleports++;
			}
			SV_LinkEdict(s);
		}
		break;
	case 6:
		PRVM_serveredictfloat(s, nextthink) = time + 0.01f;
		break;
	case 7:
		VectorNegate(PRVM_serveredictvector(s, velocity), PRVM_serveredictvector(s, velocity));
		break;
	case 8:
		if (other > 0)
			PRVM_serveredictvector(o, velocity)[2] += 50;
		break;
	case 9: // remove(other)
		if (other > 2 && other < MV_NED - 1)
			mv_priv[other].free = true;
		break;
	}
}
// prog->ExecuteProgram
static void mv_execute(prvm_prog_t *prog, func_t fnum, const char *errormessage)
{
	int i, f = (int)fnum;
	(void)errormessage;
	if (f >= 10 && f < 70)
		mv_qcthink++;
	else if (f >= 70 && f < 100)
		mv_qctouch++;
	else if (f >= 100 && f < 110)
		mv_qcblocked++;
	else if (f >= 110 && f < 120)
		mv_qctransition++;
	else if (f >= 120 && f < 130)
		mv_qcland++;
	else if (f >= 1 && f <= 4)
		mv_qcframe++;
	else
		mv_qcother++;
	printf("QC\t%d", f);
	for (i = 0; i < mv_nqcslots; i++)
		printf("\t%08x", (unsigned)prog->globals.ip[mv_qcslots[i]]);
	printf("\n");
	mv_effect(prog, f);
}

static void mv_setupprog(void)
{
	prvm_prog_t *prog = SVVM_prog;
	int ofs = 1, i; // field 0 is left unused, as in a real progs.dat
	memset(prog, 0, sizeof(*prog));
#define MV_F(name, n) do { prog->fieldoffsets.name = ofs; printf("FIELD\t%s\t%d\n", #name, ofs); ofs += (n); } while (0)
	MV_F(owner, 1);
	MV_F(solid, 1);
	MV_F(flags, 1);
	MV_F(mins, 3);
	MV_F(maxs, 3);
	MV_F(origin, 3);
	MV_F(angles, 3);
	MV_F(modelindex, 1);
	MV_F(dphitcontentsmask, 1);
	MV_F(pflags, 1);
	MV_F(movetype, 1);
	MV_F(avelocity, 3);
	MV_F(absmin, 3);
	MV_F(absmax, 3);
	MV_F(touch, 1);
	MV_F(frame, 1);
	MV_F(effects, 1);
	MV_F(velocity, 3);
	MV_F(nextthink, 1);
	MV_F(think, 1);
	MV_F(ltime, 1);
	MV_F(blocked, 1);
	MV_F(groundentity, 1);
	MV_F(watertype, 1);
	MV_F(waterlevel, 1);
	MV_F(gravity, 1);
	MV_F(bouncefactor, 1);
	MV_F(bouncestop, 1);
	MV_F(contentstransition, 1);
	MV_F(movetypesteplandevent, 1);
	MV_F(oldorigin, 3);
	MV_F(view_ofs, 3);
	MV_F(v_angle, 3);
	MV_F(punchangle, 3);
	MV_F(aiment, 1);
	MV_F(fixangle, 1);
	MV_F(classname, 1);
#undef MV_F
	if (ofs > MV_NF)
	{
		printf("TOO MANY FIELDS %d\n", ofs);
		exit(1);
	}
	printf("NFIELDS\t%d\n", MV_NF);
	ofs = MV_G0;
#define MV_G(name, n) do { prog->globaloffsets.name = ofs; printf("GLOBAL\t%s\t%d\n", #name, ofs); ofs += (n); } while (0)
	MV_G(self, 1);
	MV_G(other, 1);
	MV_G(time, 1);
	MV_G(frametime, 1);
	MV_G(force_retouch, 1);
	MV_G(trace_allsolid, 1);
	MV_G(trace_startsolid, 1);
	MV_G(trace_fraction, 1);
	MV_G(trace_inwater, 1);
	MV_G(trace_inopen, 1);
	MV_G(trace_endpos, 3);
	MV_G(trace_plane_normal, 3);
	MV_G(trace_plane_dist, 1);
	MV_G(trace_ent, 1);
	MV_G(trace_dpstartcontents, 1);
	MV_G(trace_dphitcontents, 1);
	MV_G(trace_dphitq3surfaceflags, 1);
	MV_G(trace_dphittexturename, 1);
#undef MV_G
	printf("NGLOBALS\t%d\n", MV_NG);
	// the globals each QC call line shows: self, other, time, frametime, OFS_PARM0 (3), OFS_PARM1 (1), trace_*
	mv_nqcslots = 0;
	mv_qcslots[mv_nqcslots++] = prog->globaloffsets.self;
	mv_qcslots[mv_nqcslots++] = prog->globaloffsets.other;
	mv_qcslots[mv_nqcslots++] = prog->globaloffsets.time;
	mv_qcslots[mv_nqcslots++] = prog->globaloffsets.frametime;
	mv_qcslots[mv_nqcslots++] = OFS_PARM0;
	mv_qcslots[mv_nqcslots++] = OFS_PARM0 + 1;
	mv_qcslots[mv_nqcslots++] = OFS_PARM0 + 2;
	mv_qcslots[mv_nqcslots++] = OFS_PARM1;
	for (i = prog->globaloffsets.trace_allsolid; i <= prog->globaloffsets.trace_dphittexturename; i++)
		mv_qcslots[mv_nqcslots++] = i;
	printf("QCSLOTS");
	for (i = 0; i < mv_nqcslots; i++)
		printf("\t%d", mv_qcslots[i]);
	printf("\n");
	prog->funcoffsets.StartFrame = MV_FN_START;
	prog->funcoffsets.EndFrame = MV_FN_END;
	prog->funcoffsets.PlayerPreThink = MV_FN_PRE;
	prog->funcoffsets.PlayerPostThink = MV_FN_POST;
	printf("FUNC\tStartFrame\t%d\nFUNC\tEndFrame\t%d\nFUNC\tPlayerPreThink\t%d\nFUNC\tPlayerPostThink\t%d\n", MV_FN_START, MV_FN_END, MV_FN_PRE, MV_FN_POST);
	prog->entityfields = MV_NF;
	prog->entityfieldsarea = MV_NF * MV_NED;
	prog->edictsfields = mv_fields;
	prog->edicts = mv_ed;
	prog->max_edicts = MV_NED;
	prog->num_edicts = MV_NED;
	prog->limit_edicts = MV_NED;
	prog->globals.fp = mv_globals;
	prog->name = "server";
	prog->ExecuteProgram = mv_execute;
	for (i = 0; i < MV_NED; i++)
	{
		mv_ed[i].priv.server = mv_priv + i;
		mv_ed[i].fields.fp = mv_fields + i * MV_NF;
	}
	printf("NED\t%d\n", MV_NED);
}

// ---- the server (as svphys_vectors.c spv_setbounds / spv_printmodel / spv_setupserver)
static dp_model_t mv_alias; // the submodel, typed mod_alias
static int mv_water[TV_NB], mv_nwater;
static void mv_setbounds(dp_model_t *m)
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
static void mv_printmodel(int idx, int src)
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
static void mv_setupserver(void)
{
	static const float wmins[3] = {-2048, -2048, -1024}, wmaxs[3] = {2048, 2048, 1024};
	int i;
	memset(&sv, 0, sizeof(sv));
	tv_model[0].type = mod_brushq3;
	tv_model[0].numframes = 1;
	tv_model[1].type = mod_brushq3;
	tv_model[1].numframes = 1;
	mv_setbounds(tv_model + 0);
	mv_setbounds(tv_model + 1);
	mv_alias = tv_model[1];
	mv_alias.type = mod_alias;
	mv_alias.numframes = 3;
	sv.worldmodel = tv_model + 0;
	sv.models[1] = tv_model + 0;
	sv.models[2] = tv_model + 1;
	sv.models[3] = &mv_alias;
	mv_printmodel(1, 0);
	mv_printmodel(2, 1);
	mv_printmodel(3, 1);
	sv.time = 1234.56789012345;
	printf("TIME");
	mv_pd(sv.time);
	printf("\n");
	World_SetSize(&sv.world, "maps/movers.bsp", wmins, wmaxs, SVVM_prog);
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
	for (i = 0; i < MV_NG; i++)
		mv_globals[i] = 0;
	mv_nwater = 0;
	for (i = 0; i < TV_NWORLDB; i++)
		if (tv_brush[i].colbrushf && (tv_brush[i].texture->supercontents & SUPERCONTENTS_LIQUIDSMASK))
			mv_water[mv_nwater++] = i;
	printf("WATERBRUSHES\t%d\n", mv_nwater);
}
static void mv_setframetime(double ft)
{
	sv.frametime = ft;
	printf("SFT");
	mv_pd(sv.frametime);
	printf("\n");
}

// ---- state: printing, snapshots and the differences a call made
typedef struct mv_privstate_s
{
	int free, move, susp, wfu, mark;
	float wpo[3], mf[3], mfa[3];
}
mv_privstate_t;
typedef struct mv_clstate_s
{
	int edict, begun, fixset;
	float timeout, fix[3];
}
mv_clstate_t;
static uint32_t mv_sfields[MV_NED * MV_NF], mv_sglobals[MV_NG];
static mv_privstate_t mv_spriv[MV_NED];
static mv_clstate_t mv_scl[2];

static void mv_getpriv(int n, mv_privstate_t *s)
{
	const edict_engineprivate_t *p = mv_priv + n;
	memset(s, 0, sizeof(*s));
	s->free = p->free ? 1 : 0;
	s->move = p->move ? 1 : 0;
	s->susp = p->suspendedinairflag ? 1 : 0;
	s->wfu = p->waterposition_forceupdate ? 1 : 0;
	s->mark = p->mark;
	VectorCopy(p->waterposition_origin, s->wpo);
	VectorCopy(p->moved_from, s->mf);
	VectorCopy(p->moved_fromangles, s->mfa);
}
static void mv_printpriv(const char *tag, int n)
{
	mv_privstate_t s;
	mv_getpriv(n, &s);
	printf("%s\t%d\t%d\t%d\t%d\t%d\t%d", tag, n, s.free, s.move, s.susp, s.wfu, s.mark);
	tv_pv(s.wpo);
	tv_pv(s.mf);
	tv_pv(s.mfa);
	printf("\n");
}
static void mv_getcl(int i, mv_clstate_t *s)
{
	const client_t *c = mv_clients + i;
	memset(s, 0, sizeof(*s));
	s->edict = c->edict ? (int)(c->edict - mv_ed) : -1;
	s->begun = c->begun ? 1 : 0;
	s->fixset = c->fixangle_angles_set ? 1 : 0;
	s->timeout = c->clmovement_inputtimeout;
	VectorCopy(c->fixangle_angles, s->fix);
}
static void mv_printcl(const char *tag, int i)
{
	mv_clstate_t s;
	mv_getcl(i, &s);
	printf("%s\t%d\t%d\t%d\t%d", tag, i, s.edict, s.begun, s.fixset);
	tv_pf(s.timeout);
	tv_pv(s.fix);
	printf("\n");
}
static void mv_printed(int n)
{
	int i;
	uint32_t u;
	printf("ED\t%d\t%d", n, (int)mv_priv[n].free);
	for (i = 0; i < MV_NF; i++)
	{
		memcpy(&u, mv_fields + n * MV_NF + i, 4);
		printf("\t%08x", u);
	}
	printf("\n");
}
static void mv_link(int n)
{
	prvm_prog_t *prog = SVVM_prog;
	printf("LINK\t%d\n", n);
	SV_LinkEdict(mv_ed + n);
	printf("LK\t%d", n);
	tv_pv(PRVM_serveredictvector(mv_ed + n, absmin));
	tv_pv(PRVM_serveredictvector(mv_ed + n, absmax));
	printf("\n");
}
// the full state of edict n (fields, private values) is sent, then it is linked
static void mv_commit(int n)
{
	mv_printed(n);
	mv_printpriv("PS", n);
	if (n > 0 && !mv_priv[n].free)
		mv_link(n);
}
static void mv_setfree(int n, int f)
{
	mv_priv[n].free = f;
	printf("F\t%d\t%d\n", n, f);
}
static void mv_snap(void)
{
	int n;
	memcpy(mv_sfields, mv_fields, sizeof(mv_sfields));
	memcpy(mv_sglobals, mv_globals, sizeof(mv_sglobals));
	for (n = 0; n < MV_NED; n++)
		mv_getpriv(n, mv_spriv + n);
	mv_getcl(0, mv_scl + 0);
	mv_getcl(1, mv_scl + 1);
}
// D: changed field words of an edict (slot, word pairs); GD: changed globals; P / CL: the new private / client state
static void mv_diff(void)
{
	prvm_prog_t *prog = SVVM_prog;
	int n, i, any;
	uint32_t u;
	mv_privstate_t ps;
	mv_clstate_t cs;
	for (n = 0; n < MV_NED; n++)
	{
		any = 0;
		for (i = 0; i < MV_NF; i++)
		{
			memcpy(&u, mv_fields + n * MV_NF + i, 4);
			if (u != mv_sfields[n * MV_NF + i])
			{
				if (!any)
					printf("D\t%d", n);
				any = 1;
				printf("\t%d\t%08x", i, u);
			}
		}
		if (any)
			printf("\n");
	}
	any = 0;
	for (i = 0; i < MV_NG; i++)
	{
		memcpy(&u, mv_globals + i, 4);
		if (u != mv_sglobals[i])
		{
			if (!any)
				printf("GD");
			any = 1;
			printf("\t%d\t%08x", i, u);
		}
	}
	if (any)
		printf("\n");
	for (n = 0; n < MV_NED; n++)
	{
		mv_getpriv(n, &ps);
		if (memcmp(&ps, mv_spriv + n, sizeof(ps)))
			mv_printpriv("P", n);
	}
	for (i = 0; i < 2; i++)
	{
		mv_getcl(i, &cs);
		if (memcmp(&cs, mv_scl + i, sizeof(cs)))
			mv_printcl("CL", i);
	}
	(void)prog;
}
static void mv_end(const char *ret)
{
	prvm_prog_t *prog = SVVM_prog;
	mv_diff();
	printf("E\t%s", ret);
	mv_pd(sv.time);
	printf("\t%d\n", prog->num_edicts);
}

// ---- the scene: box entities east of the world model (whose brushes end near x 600), two bmodels
typedef struct mv_box_s
{
	float o[3], mins[3], maxs[3];
}
mv_box_t;
#define MV_NBOX 16
static const mv_box_t mv_boxes[MV_NBOX] =
{
	{{1300, 0, 0}, {-500, -500, -64}, {500, 500, 0}}, // floor, top at z 0
	{{1700, 0, 0}, {0, -500, 0}, {48, 500, 256}}, // east wall
	{{1300, 420, 0}, {-500, 0, 0}, {448, 48, 256}}, // north wall (a corner with the east wall)
	{{1450, -350, 0}, {0, -40, 0}, {64, 40, 4}}, // steps of several heights
	{{1450, -250, 0}, {0, -40, 0}, {64, 40, 12}},
	{{1450, -150, 0}, {0, -40, 0}, {64, 40, 20}},
	{{1450, -50, 0}, {0, -40, 0}, {64, 40, 30}},
	{{1450, 50, 0}, {0, -40, 0}, {64, 40, 31.5f}},
	{{1450, 150, 0}, {0, -40, 0}, {64, 40, 40}},
	{{1100, -400, 0}, {0, -60, 0}, {32, 60, 16}}, // stairs
	{{1132, -400, 0}, {0, -60, 0}, {32, 60, 32}},
	{{1164, -400, 0}, {0, -60, 0}, {32, 60, 48}},
	{{1196, -400, 0}, {0, -60, 0}, {96, 60, 64}},
	{{950, 0, 70}, {-60, -60, 0}, {60, 60, 16}}, // a low ceiling 70 above the floor
	{{1000, 250, 0}, {-64, -64, 0}, {64, 64, 48}}, // a ledge to walk off (step down)
	{{1250, 250, 0}, {-40, -40, 0}, {40, 40, 10}}, // a low bump
};
static const float mv_x800[3] = {800, 0, 0}; // about where the submodel's geometry is in model space

static void mv_clearent(int n)
{
	edict_engineprivate_t *p = mv_priv + n;
	memset(mv_fields + n * MV_NF, 0, sizeof(prvm_vec_t) * MV_NF);
	p->free = false;
	p->move = false;
	p->suspendedinairflag = false;
	p->waterposition_forceupdate = false;
	p->mark = 0;
	VectorClear(p->waterposition_origin);
	VectorClear(p->moved_from);
	VectorClear(p->moved_fromangles);
}
// the transform of a submodel entity (SV_GetPitchSign: the alias-typed copy, modelindex 3, has its pitch negated)
static void mv_bspmatrix(int n, matrix4x4_t *m)
{
	prvm_prog_t *prog = SVVM_prog;
	prvm_edict_t *ed = mv_ed + n;
	const float *o = PRVM_serveredictvector(ed, origin), *a = PRVM_serveredictvector(ed, angles);
	Matrix4x4_CreateFromQuakeEntity(m, o[0], o[1], o[2], (PRVM_serveredictfloat(ed, modelindex) == 3 ? -1 : 1) * a[0], a[1], a[2], 1);
}
// the origin of a submodel entity whose geometry is to be around target
static void mv_bsptarget(int n, const float *target)
{
	prvm_prog_t *prog = SVVM_prog;
	prvm_edict_t *ed = mv_ed + n;
	float off[3], *o = PRVM_serveredictvector(ed, origin);
	matrix4x4_t m;
	VectorClear(o);
	mv_bspmatrix(n, &m);
	Matrix4x4_Transform(&m, mv_x800, off);
	VectorSubtract(target, off, o);
}
static void mv_makebsp(int n, int movetype, int modelindex, const float *angles, const float *target)
{
	prvm_prog_t *prog = SVVM_prog;
	prvm_edict_t *ed = mv_ed + n;
	mv_clearent(n);
	PRVM_serveredictfloat(ed, solid) = SOLID_BSP;
	PRVM_serveredictfloat(ed, movetype) = movetype;
	PRVM_serveredictfloat(ed, modelindex) = modelindex;
	VectorCopy(angles, PRVM_serveredictvector(ed, angles));
	VectorCopy(tv_model[1].normalmins, PRVM_serveredictvector(ed, mins));
	VectorCopy(tv_model[1].normalmaxs, PRVM_serveredictvector(ed, maxs));
	mv_bsptarget(n, target);
}
static void mv_scene(void)
{
	prvm_prog_t *prog = SVVM_prog;
	static const float zero[3] = {0, 0, 0}, rang[3] = {20, 35, 10}, bsptarget[3] = {1300, 0, 260}, rtarget[3] = {900, -150, 150};
	int i;
	prvm_edict_t *ed;
	// the world edict: what the server spawns for it
	mv_clearent(0);
	PRVM_serveredictfloat(mv_ed, solid) = SOLID_BSP;
	PRVM_serveredictfloat(mv_ed, movetype) = MOVETYPE_PUSH;
	PRVM_serveredictfloat(mv_ed, modelindex) = 1;
	mv_commit(0);
	for (i = 0; i < MV_NBOX; i++)
	{
		ed = mv_ed + MV_SCENE0 + i;
		mv_clearent(MV_SCENE0 + i);
		PRVM_serveredictfloat(ed, solid) = SOLID_BBOX;
		PRVM_serveredictfloat(ed, movetype) = MOVETYPE_NONE;
		VectorCopy(mv_boxes[i].o, PRVM_serveredictvector(ed, origin));
		VectorCopy(mv_boxes[i].mins, PRVM_serveredictvector(ed, mins));
		VectorCopy(mv_boxes[i].maxs, PRVM_serveredictvector(ed, maxs));
		mv_commit(MV_SCENE0 + i);
	}
	mv_makebsp(MV_BSP, MOVETYPE_NONE, 2, zero, bsptarget);
	mv_commit(MV_BSP);
	mv_makebsp(MV_RBSP, MOVETYPE_NONE, 2, rang, rtarget);
	mv_commit(MV_RBSP);
	mv_clearent(MV_SENT);
	PRVM_serveredictfloat(mv_ed + MV_SENT, solid) = SOLID_NOT;
	VectorSet(PRVM_serveredictvector(mv_ed + MV_SENT, origin), 1300, -300, 600);
	mv_commit(MV_SENT);
	for (i = MV_DYN0; i < MV_SENT; i++)
	{
		mv_clearent(i);
		mv_priv[i].free = true;
		mv_commit(i);
	}
}

// ---- random entities
static void mv_size(float *mins, float *maxs, int kind)
{
	int j;
	switch (kind)
	{
	case 0: // the player box
		VectorSet(mins, -16, -16, -24);
		VectorSet(maxs, 16, 16, 45);
		break;
	case 1: // an item
		VectorSet(mins, -16, -16, 0);
		VectorSet(maxs, 16, 16, 32);
		break;
	case 2: // a point
		VectorClear(mins);
		VectorClear(maxs);
		break;
	case 3: // mins == maxs, not at the origin
		for (j = 0; j < 3; j++)
			mins[j] = maxs[j] = tv_frand(-6, 6);
		break;
	case 4: // a projectile
		VectorSet(mins, -4, -4, -4);
		VectorSet(maxs, 4, 4, 4);
		break;
	default:
		for (j = 0; j < 3; j++)
		{
			mins[j] = -tv_frand(1, 40);
			maxs[j] = tv_frand(1, 40);
		}
		break;
	}
}
static int mv_randsizekind(void)
{
	int r = mv_rn(100);
	return r < 35 ? 0 : r < 50 ? 1 : r < 58 ? 2 : r < 62 ? 3 : r < 75 ? 4 : 5;
}
// a point for an entity with this box: 0 on the arena floor (or above it), 1 stuck in the floor, 2 next to or on a
// scene box, 3 on top of a world brush, 4 in / at a water brush, 5 near the static bmodel's brushes, 6 inside a
// world brush, other: anywhere around the world model
static void mv_place(const float *mins, const float *maxs, float *t, int mode)
{
	const colbrushf_t *cb;
	const mv_box_t *bx;
	int b, side;
	switch (mode)
	{
	case 0:
		t[0] = 1300 + tv_frand(-450, 450);
		t[1] = tv_frand(-450, 400);
		t[2] = -mins[2] + tv_frand(0, 1);
		if (!mv_rn(4))
			t[2] += tv_frand(4, 200);
		break;
	case 1:
		t[0] = 1300 + tv_frand(-450, 380);
		t[1] = tv_frand(-450, 400);
		t[2] = -mins[2] - tv_frand(0.25f, 12);
		break;
	case 2:
		bx = mv_boxes + 3 + mv_rn(MV_NBOX - 3);
		side = mv_rn(5);
		t[0] = bx->o[0] + tv_frand(bx->mins[0], bx->maxs[0]);
		t[1] = bx->o[1] + tv_frand(bx->mins[1], bx->maxs[1]);
		t[2] = -mins[2] + tv_frand(0, 1);
		if (side == 0)
			t[0] = bx->o[0] + bx->mins[0] - maxs[0] - tv_frand(0, 24);
		else if (side == 1)
			t[0] = bx->o[0] + bx->maxs[0] - mins[0] + tv_frand(0, 24);
		else if (side == 2)
			t[1] = bx->o[1] + bx->mins[1] - maxs[1] - tv_frand(0, 24);
		else if (side == 3)
			t[1] = bx->o[1] + bx->maxs[1] - mins[1] + tv_frand(0, 24);
		else
			t[2] = bx->o[2] + bx->maxs[2] - mins[2] + tv_frand(0, 1);
		break;
	case 3:
		b = tv_pickbrush(0);
		cb = tv_brush[b].colbrushf;
		t[0] = tv_frand(cb->mins[0], cb->maxs[0]);
		t[1] = tv_frand(cb->mins[1], cb->maxs[1]);
		t[2] = cb->maxs[2] - mins[2] + tv_frand(-1, 24);
		break;
	case 4:
		if (mv_nwater)
		{
			b = mv_water[mv_rn(mv_nwater)];
			cb = tv_brush[b].colbrushf;
			t[0] = tv_frand(cb->mins[0], cb->maxs[0]);
			t[1] = tv_frand(cb->mins[1], cb->maxs[1]);
			t[2] = tv_frand(cb->mins[2] - maxs[2] + 1, cb->maxs[2] - mins[2] + 8);
			break;
		}
		// fall through
	case 5:
		b = TV_NWORLDB + mv_rn(TV_NB - TV_NWORLDB);
		t[0] = 500 + tv_bcenter[b][0] + tv_frand(-70, 70);
		t[1] = tv_bcenter[b][1] + tv_frand(-70, 70);
		t[2] = 260 + tv_bcenter[b][2] + tv_frand(-70, 70);
		break;
	case 6:
		b = tv_pickbrush(0);
		t[0] = tv_bcenter[b][0] + tv_frand(-8, 8);
		t[1] = tv_bcenter[b][1] + tv_frand(-8, 8);
		t[2] = tv_bcenter[b][2] + tv_frand(-8, 8);
		break;
	default:
		t[0] = tv_frand(-520, 520);
		t[1] = tv_frand(-520, 520);
		t[2] = tv_frand(-520, 520);
		break;
	}
}
static int mv_randplace(void)
{
	int r = mv_rn(100);
	return r < 30 ? 0 : r < 36 ? 1 : r < 52 ? 2 : r < 64 ? 3 : r < 76 ? 4 : r < 84 ? 5 : r < 90 ? 6 : 7;
}
static int mv_pickother(int n) // another entity that is in use (mostly), for groundentity / aiment / owner
{
	int i, k = 1;
	for (i = 0; i < 30; i++)
	{
		k = 1 + mv_rn(MV_NED - 2);
		if (k != n && !mv_priv[k].free)
			return k;
	}
	return k;
}
static int mv_randmovetype(void)
{
	static const int mt[][2] =
	{
		{MOVETYPE_NONE, 5}, {MOVETYPE_WALK, 9}, {MOVETYPE_STEP, 12}, {MOVETYPE_FLY, 6}, {MOVETYPE_TOSS, 14},
		{MOVETYPE_PUSH, 5}, {MOVETYPE_NOCLIP, 4}, {MOVETYPE_FLYMISSILE, 8}, {MOVETYPE_BOUNCE, 11},
		{MOVETYPE_BOUNCEMISSILE, 6}, {MOVETYPE_FOLLOW, 6}, {MOVETYPE_FAKEPUSH, 2}, {MOVETYPE_FLY_WORLDONLY, 4},
		{MOVETYPE_PHYSICS, 3}, {150, 2}, {50, 1},
	};
	int i, total = 0, r;
	for (i = 0; i < (int)(sizeof(mt) / sizeof(mt[0])); i++)
		total += mt[i][1];
	r = mv_rn(total);
	for (i = 0; r >= mt[i][1]; i++)
		r -= mt[i][1];
	return mt[i][0];
}
// the QC fields of an entity that are not about where it is
static void mv_randfields(int n, int movetype)
{
	prvm_prog_t *prog = SVVM_prog;
	prvm_edict_t *ed = mv_ed + n;
	static const int masks[5] = {1, 0x21, 0x2000001, 0x121, 0x3};
	int r, j, pusher = movetype == MOVETYPE_PUSH || movetype == MOVETYPE_FAKEPUSH;
	float *v = PRVM_serveredictvector(ed, velocity), *av = PRVM_serveredictvector(ed, avelocity);
	r = mv_rn(100);
	if (r < 18)
		VectorClear(v);
	else if (r < 55)
		VectorSet(v, tv_frand(-400, 400), tv_frand(-400, 400), 0);
	else if (r < 75)
		VectorSet(v, tv_frand(-600, 600), tv_frand(-600, 600), tv_frand(-600, 600));
	else if (r < 84)
		VectorSet(v, tv_frand(-100, 100), tv_frand(-100, 100), -tv_frand(100, 900));
	else if (r < 92)
		VectorSet(v, tv_frand(-300, 300), tv_frand(-300, 300), tv_frand(100, 400));
	else if (r < 96)
		VectorSet(v, tv_frand(-4000, 4000), tv_frand(-4000, 4000), tv_frand(-4000, 4000));
	else
		VectorSet(v, tv_frand(-1, 1) * 1e-5f, 0, tv_frand(-1, 1) * 1e-4f);
	r = mv_rn(100);
	if (pusher)
	{
		if (r < 35)
			VectorSet(av, 0, tv_frand(-120, 120), 0);
		else if (r < 45)
			VectorSet(av, tv_frand(-60, 60), 0, 0);
		else if (r < 52)
			VectorSet(av, 0, 0, tv_frand(-60, 60));
		else if (r < 58)
			VectorSet(av, tv_frand(-60, 60), tv_frand(-60, 60), tv_frand(-60, 60));
		if (!mv_rn(12))
			VectorClear(v);
	}
	else if (r < 25)
		VectorSet(av, tv_frand(-300, 300), tv_frand(-300, 300), tv_frand(-300, 300));
	r = mv_rn(100);
	PRVM_serveredictfloat(ed, flags) = r < 38 ? 0 : r < 60 ? FL_ONGROUND : r < 64 ? (FL_ONGROUND | FL_WATERJUMP) : r < 69 ? FL_WATERJUMP
		: r < 74 ? FL_FLY : r < 78 ? FL_SWIM : r < 84 ? FL_MONSTER : r < 88 ? (FL_MONSTER | FL_ONGROUND) : r < 92 ? FL_ITEM : (FL_ITEM | FL_ONGROUND);
	r = mv_rn(100);
	if ((int)PRVM_serveredictfloat(ed, flags) & FL_ONGROUND)
		PRVM_serveredictedict(ed, groundentity) = r < 45 ? 0 : r < 65 ? MV_SCENE0 : r < 80 ? MV_SCENE0 + 1 + mv_rn(MV_NBOX - 1) : r < 88 ? MV_BSP : mv_pickother(n);
	else if (r < 10)
		PRVM_serveredictedict(ed, groundentity) = mv_pickother(n);
	r = mv_rn(100);
	PRVM_serveredictfunction(ed, think) = r < 8 ? 0 : 10 + mv_rn(60);
	r = mv_rn(100);
	if (pusher)
	{
		PRVM_serveredictfloat(ed, ltime) = (float)(sv.time + tv_frand(-0.5f, 0.5f));
		PRVM_serveredictfloat(ed, nextthink) = r < 30 ? 0 : r < 70 ? PRVM_serveredictfloat(ed, ltime) + tv_frand(0, 0.05f)
			: r < 80 ? PRVM_serveredictfloat(ed, ltime) - tv_frand(0, 0.05f) : PRVM_serveredictfloat(ed, ltime) + tv_frand(0.05f, 1);
	}
	else
		PRVM_serveredictfloat(ed, nextthink) = r < 30 ? 0 : r < 40 ? (float)(sv.time - tv_frand(0, 2)) : r < 68 ? (float)(sv.time + tv_frand(0, 0.03f))
			: r < 80 ? (float)(sv.time + tv_frand(0.03f, 1)) : r < 90 ? (float)sv.time : -1;
	PRVM_serveredictfunction(ed, touch) = mv_rn(100) < 45 ? 0 : 70 + mv_rn(30);
	PRVM_serveredictfunction(ed, blocked) = mv_rn(100) < 50 ? 0 : 100 + mv_rn(10);
	PRVM_serveredictfunction(ed, contentstransition) = mv_rn(100) < 80 ? 0 : 110 + mv_rn(10);
	PRVM_serveredictfunction(ed, movetypesteplandevent) = mv_rn(100) < 80 ? 0 : 120 + mv_rn(10);
	PRVM_serveredictfloat(ed, gravity) = mv_rn(100) < 70 ? 0 : tv_frand(0.25f, 2);
	PRVM_serveredictfloat(ed, bouncefactor) = mv_rn(100) < 55 ? 0 : tv_frand(0.1f, 1.5f);
	PRVM_serveredictfloat(ed, bouncestop) = mv_rn(100) < 55 ? 0 : tv_frand(0.01f, 0.5f);
	r = mv_rn(100);
	PRVM_serveredictfloat(ed, watertype) = r < 40 ? 0 : r < 70 ? CONTENTS_EMPTY : r < 85 ? CONTENTS_WATER : r < 90 ? CONTENTS_SLIME : CONTENTS_SOLID;
	PRVM_serveredictfloat(ed, waterlevel) = mv_rn(100) < 75 ? 0 : (float)mv_rn(4);
	if (mv_rn(100) < 70)
		VectorSet(PRVM_serveredictvector(ed, view_ofs), 0, 0, 22);
	else
		VectorSet(PRVM_serveredictvector(ed, view_ofs), tv_frand(-30, 30), tv_frand(-30, 30), tv_frand(-30, 30));
	VectorSet(PRVM_serveredictvector(ed, v_angle), tv_frand(-80, 80), tv_frand(-180, 180), mv_rn(2) ? 0 : tv_frand(-30, 30));
	if (mv_rn(2))
		VectorSet(PRVM_serveredictvector(ed, punchangle), tv_frand(-20, 20), tv_frand(-180, 180), mv_rn(2) ? 0 : tv_frand(-20, 20));
	PRVM_serveredictedict(ed, aiment) = mv_pickother(n);
	PRVM_serveredictedict(ed, owner) = mv_rn(100) < 80 ? 0 : mv_pickother(n);
	PRVM_serveredictfloat(ed, dphitcontentsmask) = mv_rn(100) < 85 ? 0 : masks[mv_rn(5)];
	r = mv_rn(10);
	for (j = 0; j < 3; j++)
		PRVM_serveredictvector(ed, oldorigin)[j] = r < 5 ? PRVM_serveredictvector(ed, origin)[j] : r < 8 ? PRVM_serveredictvector(ed, origin)[j] + tv_frand(-20, 20) : 0;
	mv_priv[n].move = mv_rn(4) != 0;
	mv_priv[n].suspendedinairflag = mv_rn(6) == 0;
	mv_priv[n].waterposition_forceupdate = mv_rn(3) == 0;
	if (mv_rn(2))
		VectorCopy(PRVM_serveredictvector(ed, origin), mv_priv[n].waterposition_origin);
}
// a random entity of this movetype at a random place
static void mv_makeent(int n, int movetype)
{
	prvm_prog_t *prog = SVVM_prog;
	prvm_edict_t *ed = mv_ed + n;
	float t[3], *a;
	int r, solid, bsp;
	mv_clearent(n);
	r = mv_rn(100);
	if (movetype == MOVETYPE_PUSH || movetype == MOVETYPE_FAKEPUSH)
		solid = r < 72 ? SOLID_BSP : r < 82 ? SOLID_BBOX : r < 88 ? SOLID_NOT : r < 93 ? SOLID_TRIGGER : r < 97 ? SOLID_SLIDEBOX : 7;
	else if (movetype == MOVETYPE_WALK || movetype == MOVETYPE_STEP)
		solid = r < 75 ? SOLID_SLIDEBOX : r < 88 ? SOLID_BBOX : r < 94 ? SOLID_CORPSE : r < 97 ? SOLID_TRIGGER : SOLID_NOT;
	else
		solid = r < 14 ? SOLID_NOT : r < 30 ? SOLID_TRIGGER : r < 58 ? SOLID_BBOX : r < 72 ? SOLID_SLIDEBOX : r < 92 ? SOLID_CORPSE : SOLID_BSP;
	bsp = solid == SOLID_BSP;
	PRVM_serveredictfloat(ed, solid) = solid;
	PRVM_serveredictfloat(ed, movetype) = movetype;
	a = PRVM_serveredictvector(ed, angles);
	r = mv_rn(10);
	if (r < 4)
		VectorClear(a);
	else if (r < 7)
		VectorSet(a, 0, tv_frand(-180, 180), 0);
	else
		VectorSet(a, tv_frand(-60, 60), tv_frand(-180, 180), tv_frand(-45, 45));
	if (bsp || movetype == MOVETYPE_PUSH || movetype == MOVETYPE_FAKEPUSH)
	{
		r = mv_rn(100);
		PRVM_serveredictfloat(ed, modelindex) = r < 80 ? 2 : r < 92 ? 3 : r < 96 ? 1 : r < 98 ? 0 : 9000;
		if (bsp || mv_rn(2))
		{
			VectorCopy(tv_model[1].normalmins, PRVM_serveredictvector(ed, mins));
			VectorCopy(tv_model[1].normalmaxs, PRVM_serveredictvector(ed, maxs));
		}
		else
			mv_size(PRVM_serveredictvector(ed, mins), PRVM_serveredictvector(ed, maxs), 5);
		r = mv_rn(10);
		if (r < 6) // in the arena's air
			VectorSet(t, 1300 + tv_frand(-250, 250), tv_frand(-250, 250), tv_frand(120, 420));
		else if (r < 9) // among the world brushes
			VectorSet(t, tv_frand(-350, 350), tv_frand(-350, 350), tv_frand(-350, 350));
		else
			VectorSet(t, 1300 + tv_frand(-250, 250), tv_frand(-250, 250), tv_frand(-40, 40));
		if (PRVM_serveredictfloat(ed, modelindex) >= 2 && PRVM_serveredictfloat(ed, modelindex) <= 3)
			mv_bsptarget(n, t);
		else
			VectorCopy(t, PRVM_serveredictvector(ed, origin));
	}
	else
	{
		mv_size(PRVM_serveredictvector(ed, mins), PRVM_serveredictvector(ed, maxs), mv_randsizekind());
		mv_place(PRVM_serveredictvector(ed, mins), PRVM_serveredictvector(ed, maxs), t, mv_randplace());
		VectorCopy(t, PRVM_serveredictvector(ed, origin));
	}
	mv_randfields(n, movetype);
}
// a client entity (edicts 1 and 2) and its client_t
static void mv_makeclient(int i)
{
	static const int others[12] = {MOVETYPE_FLY, MOVETYPE_NOCLIP, MOVETYPE_STEP, MOVETYPE_TOSS, MOVETYPE_FOLLOW, MOVETYPE_NONE, MOVETYPE_PUSH, MOVETYPE_PHYSICS, MOVETYPE_FLY_WORLDONLY, MOVETYPE_BOUNCE, 150, 50};
	prvm_prog_t *prog = SVVM_prog;
	int n = i + 1, r, movetype = mv_rn(100) < 50 ? MOVETYPE_WALK : others[mv_rn(12)];
	prvm_edict_t *ed = mv_ed + n;
	client_t *c = mv_clients + i;
	float t[3];
	mv_clearent(n);
	PRVM_serveredictfloat(ed, solid) = SOLID_SLIDEBOX;
	PRVM_serveredictfloat(ed, movetype) = movetype;
	mv_size(PRVM_serveredictvector(ed, mins), PRVM_serveredictvector(ed, maxs), 0);
	r = mv_rn(100);
	mv_place(PRVM_serveredictvector(ed, mins), PRVM_serveredictvector(ed, maxs), t, r < 40 ? 0 : r < 70 ? 2 : r < 85 ? 4 : r < 92 ? 3 : 1);
	VectorCopy(t, PRVM_serveredictvector(ed, origin));
	mv_randfields(n, movetype);
	r = mv_rn(100);
	VectorSet(PRVM_serveredictvector(ed, velocity), tv_frand(-360, 360), tv_frand(-360, 360), r < 20 ? 270 : r < 30 ? -tv_frand(0, 600) : 0);
	PRVM_serveredictfloat(ed, flags) = r < 65 ? FL_ONGROUND : r < 70 ? FL_WATERJUMP : 0;
	PRVM_serveredictedict(ed, groundentity) = mv_rn(2) ? MV_SCENE0 : 0;
	VectorSet(PRVM_serveredictvector(ed, view_ofs), 0, 0, 35);
	PRVM_serveredictfunction(ed, think) = mv_rn(3) ? 0 : 10 + mv_rn(60);
	PRVM_serveredictfloat(ed, nextthink) = mv_rn(3) ? 0 : (float)(sv.time + tv_frand(0, 0.03f));
	mv_priv[n].move = true;
	memset(c, 0, sizeof(*c));
	c->edict = ed;
	c->begun = mv_rn(100) < 88;
	c->clmovement_inputtimeout = mv_rn(100) < 78 ? 0 : tv_frand(0.005f, 0.08f);
	mv_commit(n);
	mv_printcl("CLS", i);
}
// a population of clients and random entities in edicts MV_DYN0 .. first + count - 1 (the rest are freed)
static void mv_population(int first, int count)
{
	int n;
	mv_makeclient(0);
	mv_makeclient(1);
	for (n = first; n < MV_SENT; n++)
	{
		if (n < first + count)
		{
			mv_makeent(n, mv_randmovetype());
			mv_commit(n);
		}
		else if (!mv_priv[n].free)
			mv_setfree(n, 1);
	}
}
// a pusher (edict first) with riders and things in its way after it; returns the next free edict
static int mv_pushscene(int first)
{
	static const int rmt[13] = {MOVETYPE_WALK, MOVETYPE_STEP, MOVETYPE_TOSS, MOVETYPE_BOUNCE, MOVETYPE_FLY, MOVETYPE_NONE, MOVETYPE_PUSH, MOVETYPE_FOLLOW, MOVETYPE_NOCLIP, MOVETYPE_PHYSICS, MOVETYPE_FLYMISSILE, MOVETYPE_FLY_WORLDONLY, MOVETYPE_BOUNCEMISSILE};
	static const int rsolid[8] = {SOLID_SLIDEBOX, SOLID_SLIDEBOX, SOLID_BBOX, SOLID_BBOX, SOLID_CORPSE, SOLID_NOT, SOLID_TRIGGER, SOLID_SLIDEBOX};
	prvm_prog_t *prog = SVVM_prog;
	int n0 = first, n, k, count, r, b, j;
	prvm_edict_t *p = mv_ed + n0, *ed;
	float t[3], ang[3], pt[3], w[3];
	matrix4x4_t m;
	const colbrushf_t *cb;
	r = mv_rn(10);
	if (r < 4)
		VectorClear(ang);
	else if (r < 7)
		VectorSet(ang, 0, tv_frand(-180, 180), 0);
	else
		VectorSet(ang, tv_frand(-40, 40), tv_frand(-180, 180), tv_frand(-30, 30));
	r = mv_rn(10);
	if (r < 6)
		VectorSet(t, 1300 + tv_frand(-200, 200), tv_frand(-200, 200), tv_frand(150, 400));
	else if (r < 8)
		VectorSet(t, 1300 + tv_frand(-200, 200), tv_frand(-200, 200), tv_frand(-30, 60));
	else
		VectorSet(t, tv_frand(-300, 300), tv_frand(-300, 300), tv_frand(-300, 300));
	mv_makebsp(n0, mv_rn(20) ? MOVETYPE_PUSH : MOVETYPE_FAKEPUSH, mv_rn(8) ? 2 : 3, ang, t);
	r = mv_rn(20);
	if (r == 0)
		PRVM_serveredictfloat(p, solid) = SOLID_BBOX;
	else if (r == 1)
		PRVM_serveredictfloat(p, solid) = SOLID_NOT;
	mv_randfields(n0, MOVETYPE_PUSH);
	PRVM_serveredictfloat(p, flags) = 0;
	if (mv_rn(10) < 7)
		VectorSet(PRVM_serveredictvector(p, velocity), tv_frand(-320, 320), tv_frand(-320, 320), tv_frand(-320, 320));
	mv_commit(n0);
	count = 4 + mv_rn(9);
	for (k = 1; k <= count; k++)
	{
		n = n0 + k;
		ed = mv_ed + n;
		mv_clearent(n);
		PRVM_serveredictfloat(ed, movetype) = rmt[mv_rn(13)];
		PRVM_serveredictfloat(ed, solid) = rsolid[mv_rn(8)];
		mv_size(PRVM_serveredictvector(ed, mins), PRVM_serveredictvector(ed, maxs), mv_randsizekind());
		r = mv_rn(100);
		mv_bspmatrix(n0, &m);
		if (r < 30) // standing on one of the pusher's brushes
		{
			b = TV_NWORLDB + mv_rn(TV_NB - TV_NWORLDB);
			cb = tv_brush[b].colbrushf;
			if (!cb)
				cb = tv_brush[TV_NWORLDB + 1].colbrushf;
			if (cb)
				VectorSet(pt, tv_frand(cb->mins[0], cb->maxs[0]), tv_frand(cb->mins[1], cb->maxs[1]), cb->maxs[2]);
			else
				VectorCopy(mv_x800, pt);
			Matrix4x4_Transform(&m, pt, w);
			w[2] += -PRVM_serveredictvector(ed, mins)[2] + 0.125f;
		}
		else if (r < 55) // inside one of its brushes
		{
			b = TV_NWORLDB + mv_rn(TV_NB - TV_NWORLDB);
			for (j = 0; j < 3; j++)
				pt[j] = tv_bcenter[b][j] + tv_frand(-12, 12);
			Matrix4x4_Transform(&m, pt, w);
		}
		else // somewhere in its box
		{
			for (j = 0; j < 3; j++)
				w[j] = tv_frand(PRVM_serveredictvector(p, absmin)[j] - 32, PRVM_serveredictvector(p, absmax)[j] + 32);
		}
		VectorCopy(w, PRVM_serveredictvector(ed, origin));
		mv_randfields(n, (int)PRVM_serveredictfloat(ed, movetype));
		if (r < 30 || mv_rn(4) == 0)
		{
			PRVM_serveredictfloat(ed, flags) = FL_ONGROUND;
			PRVM_serveredictedict(ed, groundentity) = r < 30 ? n0 : mv_pickother(n);
		}
		if (mv_rn(12) == 0)
			PRVM_serveredictedict(ed, owner) = n0;
		if (mv_rn(6) == 0) // teleported (setorigin) when it is pushed into something
			PRVM_serveredictfunction(ed, touch) = 75;
		mv_commit(n);
	}
	if (mv_rn(8) == 0)
	{
		PRVM_serveredictedict(p, owner) = n0 + 1;
		mv_commit(n0);
	}
	return n0 + count + 1;
}

// the calls of the cases
enum
{
	MV_TEP, MV_CCT, MV_CV, MV_RT, MV_IMP, MV_FLY, MV_GRAV, MV_NPK, MV_PE, MV_UNO, MV_UN, MV_CS, MV_CW, MV_WF, MV_WM,
	MV_FOL, MV_CWT, MV_TOSS, MV_STEP, MV_PENT, MV_CNT, MV_CMOVE, MV_CPRE, MV_CPOST, MV_CENT, MV_PM, MV_PP, MV_PHYS,
	MV_CLIP, MV_AVF, MV_NOPS
};

// an entity of the cases set up next to something to run into: 0 dropping onto the arena floor, 1 next to a scene
// box (steps, walls, stairs, ledge, bump) moving into it, 2 into the corner of the walls, 3 at the stairs, 4 walking
// off the ledge, 5 just above a world brush (some have sloped tops), 6 / 7 next to a brush of the static / rotated
// bmodel moving into it, 8 at some depth in a water brush, 9 sunk into the top of a world brush (stuck),
// 10 under the low ceiling
static void mv_fresh(int n, int movetype, int kind, int sizekind)
{
	prvm_prog_t *prog = SVVM_prog;
	prvm_edict_t *ed = mv_ed + n;
	float *o, *v, *mins, *maxs, c[3], d[3], k, depth;
	const mv_box_t *bx;
	const colbrushf_t *cb;
	matrix4x4_t m;
	int b, j, side;
	mv_makeent(n, movetype);
	mins = PRVM_serveredictvector(ed, mins);
	maxs = PRVM_serveredictvector(ed, maxs);
	if (PRVM_serveredictfloat(ed, solid) == SOLID_BSP)
	{
		PRVM_serveredictfloat(ed, solid) = SOLID_SLIDEBOX;
		PRVM_serveredictfloat(ed, modelindex) = 0;
		VectorClear(PRVM_serveredictvector(ed, angles));
		mv_size(mins, maxs, mv_randsizekind());
	}
	if (sizekind >= 0)
		mv_size(mins, maxs, sizekind);
	if (mv_rn(5)) // mostly something that collides with the box entities
	{
		PRVM_serveredictfloat(ed, solid) = mv_rn(2) ? SOLID_SLIDEBOX : SOLID_BBOX;
		if (mv_rn(6))
			PRVM_serveredictfloat(ed, dphitcontentsmask) = 0;
	}
	o = PRVM_serveredictvector(ed, origin);
	v = PRVM_serveredictvector(ed, velocity);
	k = tv_frand(1.1f, 4) / (float)sv.frametime; // a velocity that gets there in 1 / 4 .. 1 / 1.1 frames
	switch (kind)
	{
	case 0:
		VectorSet(o, 1300 + tv_frand(-400, 400), tv_frand(-400, 380), -mins[2] + tv_frand(0, 30));
		VectorSet(v, tv_frand(-300, 300), tv_frand(-300, 300), -tv_frand(100, 1500));
		break;
	case 1:
		bx = mv_boxes + 3 + mv_rn(MV_NBOX - 3);
		if (bx == mv_boxes + 13)
			bx = mv_boxes + 4;
		side = mv_rn(4);
		o[0] = bx->o[0] + tv_frand(bx->mins[0], bx->maxs[0]);
		o[1] = bx->o[1] + tv_frand(bx->mins[1], bx->maxs[1]);
		o[2] = -mins[2] + tv_frand(0, 1);
		if (side == 0)
			o[0] = bx->o[0] + bx->mins[0] - maxs[0] - tv_frand(0, 24);
		else if (side == 1)
			o[0] = bx->o[0] + bx->maxs[0] - mins[0] + tv_frand(0, 24);
		else if (side == 2)
			o[1] = bx->o[1] + bx->mins[1] - maxs[1] - tv_frand(0, 24);
		else
			o[1] = bx->o[1] + bx->maxs[1] - mins[1] + tv_frand(0, 24);
		for (j = 0; j < 2; j++)
			c[j] = bx->o[j] + 0.5f * (bx->mins[j] + bx->maxs[j]);
		v[0] = (c[0] - o[0]) * k;
		v[1] = (c[1] - o[1]) * k;
		v[2] = mv_rn(3) ? 0 : tv_frand(-100, 300);
		break;
	case 2:
		VectorSet(o, 1700 - maxs[0] - tv_frand(0, 30), 420 - maxs[1] - tv_frand(0, 30), -mins[2] + tv_frand(0, 1));
		VectorSet(v, tv_frand(300, 1500), mv_rn(2) ? tv_frand(300, 1500) : tv_frand(-300, 300), mv_rn(2) ? 0 : -tv_frand(0, 200));
		break;
	case 3:
		VectorSet(o, 1100 - maxs[0] - tv_frand(0, 40), -400 + tv_frand(-50, 50), -mins[2] + tv_frand(0, 1));
		VectorSet(v, tv_frand(300, 1200), tv_frand(-50, 50), 0);
		break;
	case 4:
		VectorSet(o, 1000 + tv_frand(-64, 64), 250 + tv_frand(-64, 64), 48 - mins[2] + tv_frand(0, 0.5f));
		VectorSet(d, o[0] - 1000, o[1] - 250, 0);
		VectorNormalize(d);
		VectorScale(d, tv_frand(100, 450), v);
		PRVM_serveredictfloat(ed, flags) = (int)PRVM_serveredictfloat(ed, flags) | FL_ONGROUND;
		PRVM_serveredictedict(ed, groundentity) = MV_SCENE0 + 14;
		break;
	case 5:
		b = tv_pickbrush(0);
		cb = tv_brush[b].colbrushf;
		VectorSet(o, tv_frand(cb->mins[0], cb->maxs[0]), tv_frand(cb->mins[1], cb->maxs[1]), cb->maxs[2] - mins[2] + tv_frand(0, 6));
		VectorSet(v, tv_frand(-300, 300), tv_frand(-300, 300), -tv_frand(50, 800));
		break;
	case 6:
	case 7:
		b = TV_NWORLDB + mv_rn(TV_NB - TV_NWORLDB);
		mv_bspmatrix(kind == 6 ? MV_BSP : MV_RBSP, &m);
		Matrix4x4_Transform(&m, tv_bcenter[b], c);
		tv_randnormal(d);
		VectorMA(c, tv_frand(30, 120), d, o);
		VectorSubtract(c, o, v);
		VectorScale(v, k, v);
		break;
	case 8:
		if (!mv_nwater)
			break;
		b = mv_water[mv_rn(mv_nwater)];
		cb = tv_brush[b].colbrushf;
		depth = tv_frand(-10, maxs[2] - mins[2] + 10);
		VectorSet(o, tv_frand(cb->mins[0] + 4, cb->maxs[0] - 4), tv_frand(cb->mins[1] + 4, cb->maxs[1] - 4), cb->maxs[2] - mins[2] - depth);
		VectorSet(v, tv_frand(-200, 200), tv_frand(-200, 200), tv_frand(-200, 200));
		if (mv_rn(4) == 0)
			PRVM_serveredictfloat(ed, flags) = (int)PRVM_serveredictfloat(ed, flags) | FL_WATERJUMP;
		break;
	case 9:
		b = tv_pickbrush(0);
		cb = tv_brush[b].colbrushf;
		VectorSet(o, tv_frand(cb->mins[0], cb->maxs[0]), tv_frand(cb->mins[1], cb->maxs[1]), cb->maxs[2] - mins[2] - tv_frand(0.25f, 17));
		VectorSet(v, tv_frand(-200, 200), tv_frand(-200, 200), tv_frand(-100, 100));
		break;
	default:
		VectorSet(o, 950 + tv_frand(-50, 50), tv_frand(-50, 50), -mins[2] + tv_frand(0, 1));
		VectorSet(v, tv_frand(-600, 600), tv_frand(-600, 600), mv_rn(2) ? tv_frand(300, 1200) : 0);
		break;
	}
	for (j = 0; j < 3; j++)
		v[j] = bound(-3000, v[j], 3000);
	VectorCopy(o, PRVM_serveredictvector(ed, oldorigin));
	if (mv_rn(3) == 0)
		VectorCopy(o, mv_priv[n].waterposition_origin);
}
// a fresh entity in the scratch edicts (MV_DYN0 + 44 ..) set up for op, or -1 (op runs on an existing entity)
static int mv_freshfor(int op)
{
	static const int wmk[12] = {0, 1, 1, 2, 3, 3, 4, 4, 5, 8, 10, 9};
	static const int tossk[9] = {0, 0, 5, 5, 6, 7, 1, 2, 4};
	static const int tossmt[8] = {MOVETYPE_TOSS, MOVETYPE_BOUNCE, MOVETYPE_BOUNCE, MOVETYPE_BOUNCEMISSILE, MOVETYPE_FLYMISSILE, MOVETYPE_FLY, MOVETYPE_FLY_WORLDONLY, MOVETYPE_TOSS};
	static const int stepk[6] = {0, 0, 5, 4, 8, 1};
	static const int stuckk[7] = {9, 9, 9, 6, 7, 8, 5};
	static const int tepk[5] = {9, 9, 0, 5, 6};
	static const int waterk[5] = {8, 8, 8, 0, 5};
	static const int npkk[4] = {9, 6, 7, 5};
	prvm_prog_t *prog = SVVM_prog;
	int n = MV_DYN0 + 44 + mv_rn(20), mt, kind, sizekind = -1, r, fl;
	prvm_edict_t *ed = mv_ed + n;
	switch (op)
	{
	case MV_FLY:
	case MV_PE:
	case MV_PENT:
		mt = mv_randmovetype();
		kind = mv_rn(11);
		break;
	case MV_WM:
		mt = mv_rn(100) < 85 ? MOVETYPE_WALK : (mv_rn(2) ? MOVETYPE_FLY : MOVETYPE_STEP);
		kind = wmk[mv_rn(12)];
		sizekind = mv_rn(5) ? 0 : 5;
		break;
	case MV_TOSS:
		mt = tossmt[mv_rn(8)];
		kind = tossk[mv_rn(9)];
		break;
	case MV_STEP:
		mt = MOVETYPE_STEP;
		kind = stepk[mv_rn(6)];
		break;
	case MV_UNO:
	case MV_UN:
	case MV_CS:
		mt = mv_rn(2) ? MOVETYPE_WALK : mv_randmovetype();
		kind = stuckk[mv_rn(7)];
		sizekind = mv_rn(2) ? 0 : -1;
		break;
	case MV_TEP:
		mt = mv_randmovetype();
		kind = tepk[mv_rn(5)];
		break;
	case MV_CW:
	case MV_CWT:
		mt = mv_randmovetype();
		kind = waterk[mv_rn(5)];
		sizekind = mv_rn(2) ? 0 : -1;
		break;
	case MV_NPK:
		mt = mv_randmovetype();
		kind = npkk[mv_rn(4)];
		break;
	default:
		return -1;
	}
	mv_fresh(n, mt, kind, sizekind);
	fl = (int)PRVM_serveredictfloat(ed, flags);
	r = mv_rn(4);
	if (op == MV_WM)
	{
		PRVM_serveredictfloat(ed, solid) = SOLID_SLIDEBOX;
		if (kind != 4)
		{
			PRVM_serveredictfloat(ed, flags) = r < 3 ? (fl | FL_ONGROUND) : (fl & ~FL_ONGROUND);
			PRVM_serveredictedict(ed, groundentity) = MV_SCENE0;
		}
	}
	else if (op == MV_TOSS && r == 0) // a slow landing (bouncestop)
		PRVM_serveredictvector(ed, velocity)[2] = -tv_frand(0, 40);
	else if (op == MV_STEP)
	{
		if (r < 2)
		{
			PRVM_serveredictfloat(ed, flags) = fl & ~(FL_ONGROUND | FL_FLY | FL_SWIM);
			PRVM_serveredictvector(ed, velocity)[2] = -tv_frand(80, 1500);
		}
		else if (r == 2)
		{
			PRVM_serveredictfloat(ed, flags) = (fl | FL_ONGROUND) & ~(FL_FLY | FL_SWIM);
			PRVM_serveredictvector(ed, velocity)[2] = tv_frand(0.0625f, 200);
		}
		if (mv_rn(2))
			PRVM_serveredictfunction(ed, movetypesteplandevent) = 120 + mv_rn(10);
	}
	else if ((op == MV_PE || op == MV_FLY) && r == 0) // a touch function that teleports (setorigin)
		PRVM_serveredictfunction(ed, touch) = 75;
	if (op == MV_TOSS && mv_rn(5) == 0) // a touch function that removes the entity
		PRVM_serveredictfunction(ed, touch) = 74;
	mv_commit(n);
	return n;
}

// ---- the calls
static const char *mv_opname[MV_NOPS] =
{
	"TEP", "CCT", "CV", "RT", "IMP", "FLY", "GRAV", "NPK", "PE", "UNO", "UN", "CS", "CW", "WF", "WM",
	"FOL", "CWT", "TOSS", "STEP", "PENT", "CNT", "CMOVE", "CPRE", "CPOST", "CENT", "PM", "PP", "PHYS",
	"CLIP", "AVF",
};
static int mv_pickent(void)
{
	int i, n = MV_DYN0;
	for (i = 0; i < 40; i++)
	{
		n = mv_rn(6) == 0 ? 1 + mv_rn(2) : MV_DYN0 + mv_rn(MV_SENT - MV_DYN0);
		if (!mv_priv[n].free)
			return n;
	}
	return n;
}
static void mv_tracestr(char *buf, const trace_t *t)
{
	char *p = buf;
	uint32_t u;
	int j;
	p += sprintf(p, "%d\t%d\t%d\t%d\t%016llx", t->allsolid, t->startsolid, t->worldstartsolid, t->bmodelstartsolid, tv_dbits(t->fraction));
	for (j = 0; j < 3; j++)
		p += sprintf(p, "\t%016llx", tv_dbits(t->endpos[j]));
	for (j = 0; j < 3; j++)
	{
		u = tv_bits(t->plane.normal[j]);
		p += sprintf(p, "\t%08x", u);
	}
	u = tv_bits(t->plane.dist);
	sprintf(p, "\t%08x\t%d", u, t->ent ? (int)((prvm_edict_t *)t->ent - mv_ed) : -1);
}
static void mv_vstr(char *buf, const float *v)
{
	sprintf(buf, "%08x\t%08x\t%08x", tv_bits(v[0]), tv_bits(v[1]), tv_bits(v[2]));
}
static void mv_sethost(int i)
{
	host_client = mv_clients + i;
	printf("HC\t%d\n", i);
}

// one call of op on edict n (n is ignored by the ops that do not take one)
static void mv_call(int op, int n)
{
	prvm_prog_t *prog = SVVM_prog;
	prvm_edict_t *ed = mv_ed + n;
	char ret[512], s1[64], s2[64], s3[64];
	float v[3], w[3], f;
	int r, i, j, k;
	trace_t t;
	mv_calls[op]++;
	switch (op)
	{
	case MV_TEP:
		r = mv_rn(4);
		if (r == 0)
			VectorClear(v);
		else if (r == 1)
			VectorSet(v, 0, 0, (float)(mv_rn(2) ? -1 : 1) * (1 + mv_rn(6)));
		else
			VectorSet(v, tv_frand(-4, 4), tv_frand(-4, 4), tv_frand(-4, 4));
		printf("C\tTEP\t%d", n);
		tv_pv(v);
		printf("\n");
		mv_snap();
		sprintf(ret, "%d", SV_TestEntityPosition(ed, v));
		mv_end(ret);
		break;
	case MV_CCT:
		k = -1 - mv_rn(6);
		printf("C\tCCT\t%d\t%d\n", n, k);
		mv_snap();
		sprintf(ret, "%d", SV_CheckContentsTransition(ed, k));
		mv_end(ret);
		break;
	case MV_CV:
		r = mv_rn(10);
		if (r < 3) // a NaN velocity or origin component
		{
			uint32_t nan = 0x7fc00000u;
			if (r < 2)
				memcpy(PRVM_serveredictvector(ed, velocity) + mv_rn(3), &nan, 4);
			else
				memcpy(PRVM_serveredictvector(ed, origin) + mv_rn(3), &nan, 4);
			mv_printed(n);
		}
		else if (r < 5) // faster than sv_maxvelocity (2000 in the engine's own config)
		{
			VectorSet(PRVM_serveredictvector(ed, velocity), tv_frand(-4000, 4000), tv_frand(-4000, 4000), tv_frand(-4000, 4000));
			mv_printed(n);
		}
		else if (r < 6) // denormal-ish
		{
			VectorSet(PRVM_serveredictvector(ed, velocity), tv_frand(-1, 1) * 1e-4f, tv_frand(-1, 1) * 2e-4f, 0);
			mv_printed(n);
		}
		printf("C\tCV\t%d\n", n);
		mv_snap();
		SV_CheckVelocity(ed);
		mv_end("-");
		break;
	case MV_RT:
		printf("C\tRT\t%d\n", n);
		mv_snap();
		sprintf(ret, "%d", SV_RunThink(ed));
		mv_end(ret);
		break;
	case MV_IMP:
		memset(&t, 0, sizeof(t));
		t.allsolid = mv_rn(5) == 0;
		t.startsolid = mv_rn(4) == 0;
		t.inwater = mv_rn(4) == 0;
		t.inopen = mv_rn(2);
		t.fraction = tv_frand(0, 1);
		for (j = 0; j < 3; j++)
			t.endpos[j] = PRVM_serveredictvector(ed, origin)[j] + tv_frand(-30, 30);
		tv_randnormal(t.plane.normal);
		t.plane.dist = tv_frand(-500, 500);
		k = mv_rn(5) == 0 ? 0 : mv_pickent();
		t.ent = mv_ed + k;
		t.startsupercontents = mv_rn(4);
		t.hitsupercontents = mv_rn(2) ? 1 : 0x20;
		t.hitq3surfaceflags = mv_rn(3) * 0x10;
		r = mv_rn(TV_NTEX + 1) - 1;
		t.hittexture = r < 0 ? NULL : tv_tex + r;
		printf("C\tIMP\t%d\t%d\t%d\t%d\t%d", n, t.allsolid, t.startsolid, t.inwater, t.inopen);
		mv_pd(t.fraction);
		mv_pd(t.endpos[0]);
		mv_pd(t.endpos[1]);
		mv_pd(t.endpos[2]);
		tv_pv(t.plane.normal);
		tv_pf(t.plane.dist);
		printf("\t%d\t%d\t%d\t%d\t%d\n", k, t.startsupercontents, t.hitsupercontents, t.hitq3surfaceflags, r);
		mv_snap();
		SV_Impact(ed, &t);
		mv_end("-");
		break;
	case MV_FLY:
		r = mv_rn(10);
		f = r < 6 ? (float)sv.frametime : r < 9 ? tv_frand(0.001f, 0.1f) : (r == 9 && mv_rn(2) ? 0 : -0.01f);
		i = mv_rn(3) != 0; // applygravity
		j = mv_rn(2); // stepnormal
		r = mv_rn(10);
		v[0] = r < 4 ? 0 : r < 8 ? sv_stepheight.value : tv_frand(1, 40); // stepheight
		k = SV_GenericHitSuperContentsMask(ed);
		printf("C\tFLY\t%d", n);
		tv_pf(f);
		printf("\t%d\t%d\t%d", i, j, k);
		tv_pf(v[0]);
		printf("\n");
		mv_snap();
		VectorClear(w);
		r = SV_FlyMove(ed, f, i, j ? w : NULL, k, 0, 0, v[0]);
		mv_flyblocked[r & 15]++;
		if (j && (w[0] || w[1] || w[2]))
			mv_flystep++;
		mv_vstr(s1, w);
		sprintf(ret, "%d\t%s", r, s1);
		mv_end(ret);
		break;
	case MV_GRAV:
		printf("C\tGRAV\t%d\n", n);
		mv_snap();
		f = SV_Gravity(ed);
		sprintf(ret, "%08x", tv_bits(f));
		mv_end(ret);
		break;
	case MV_NPK:
		if (mv_rn(3))
			VectorLerp(PRVM_serveredictvector(ed, mins), 0.5f, PRVM_serveredictvector(ed, maxs), v);
		else
			VectorSet(v, tv_frand(-8, 8), tv_frand(-8, 8), tv_frand(-8, 8));
		printf("C\tNPK\t%d", n);
		tv_pv(v);
		printf("\n");
		mv_snap();
		sprintf(ret, "%d", SV_NudgeOutOfSolid_PivotIsKnownGood(ed, v));
		mv_end(ret);
		break;
	case MV_PE:
		r = mv_rn(10);
		if (r < 6)
			VectorScale(PRVM_serveredictvector(ed, velocity), (float)sv.frametime, v);
		else if (r < 9)
			VectorSet(v, tv_frand(-64, 64), tv_frand(-64, 64), tv_frand(-64, 64));
		else
			VectorClear(v);
		i = mv_rn(2);
		printf("C\tPE\t%d", n);
		tv_pv(v);
		printf("\t%d\n", i);
		mv_snap();
		r = SV_PushEntity(&t, ed, v, i);
		if (!r)
			mv_pefalse++;
		if (t.worldstartsolid)
			mv_peworldstuck++;
		{
			char tb[400];
			mv_tracestr(tb, &t);
			sprintf(ret, "%d\t%s", r, tb);
		}
		mv_end(ret);
		break;
	case MV_UNO:
		printf("C\tUNO\t%d\n", n);
		mv_snap();
		VectorClear(v);
		r = SV_UnstickEntityReturnOffset(ed, v);
		mv_unstick[r < 0 || r > 2 ? 0 : r]++;
		mv_vstr(s1, v);
		sprintf(ret, "%d\t%s", r, s1);
		mv_end(ret);
		break;
	case MV_UN:
		printf("C\tUN\t%d\n", n);
		mv_snap();
		sprintf(ret, "%d", SV_UnstickEntity(ed));
		mv_end(ret);
		break;
	case MV_CS:
		printf("C\tCS\t%d\n", n);
		mv_snap();
		SV_CheckStuck(ed);
		mv_end("-");
		break;
	case MV_CW:
		printf("C\tCW\t%d\n", n);
		mv_snap();
		r = SV_CheckWater(ed);
		i = (int)PRVM_serveredictfloat(ed, waterlevel);
		mv_waterlevels[i < 0 || i > 3 ? 0 : i]++;
		sprintf(ret, "%d", r);
		mv_end(ret);
		break;
	case MV_WF:
		if (mv_rn(2))
		{
			tv_randnormal(v);
			v[2] = 0;
			if (!v[0] && !v[1])
				v[0] = 1;
		}
		else
			tv_randnormal(v);
		printf("C\tWF\t%d", n);
		tv_pv(v);
		printf("\n");
		mv_snap();
		SV_WallFriction(ed, v);
		mv_end("-");
		break;
	case MV_WM:
		VectorCopy(PRVM_serveredictvector(ed, origin), w);
		printf("C\tWM\t%d\n", n);
		mv_snap();
		SV_WalkMove(ed);
		if (PRVM_serveredictvector(ed, origin)[2] > w[2] + 1)
			mv_wmup++;
		else if (PRVM_serveredictvector(ed, origin)[2] < w[2] - 1)
			mv_wmdown++;
		else if (VectorCompare(PRVM_serveredictvector(ed, origin), w))
			mv_wmrevert++;
		mv_end("-");
		break;
	case MV_FOL:
		printf("C\tFOL\t%d\n", n);
		mv_snap();
		SV_Physics_Follow(ed);
		mv_end("-");
		break;
	case MV_CWT:
		printf("C\tCWT\t%d\n", n);
		mv_snap();
		SV_CheckWaterTransition(ed);
		mv_end("-");
		break;
	case MV_TOSS:
		printf("C\tTOSS\t%d\n", n);
		mv_snap();
		SV_Physics_Toss(ed);
		if ((int)PRVM_serveredictfloat(ed, flags) & FL_ONGROUND)
			mv_tosslanded++;
		else if (PRVM_serveredictvector(ed, velocity)[2] > 0 && ((prvm_vec_t *)(mv_sfields + n * MV_NF + prog->fieldoffsets.velocity))[2] < 0)
			mv_tossbounced++;
		mv_end("-");
		break;
	case MV_STEP:
		printf("C\tSTEP\t%d\n", n);
		mv_snap();
		SV_Physics_Step(ed);
		mv_end("-");
		break;
	case MV_PENT:
		printf("C\tPENT\t%d\n", n);
		mv_snap();
		SV_Physics_Entity(ed);
		mv_end("-");
		break;
	case MV_CNT:
	case MV_CMOVE:
	case MV_CPRE:
	case MV_CPOST:
	case MV_CENT:
		i = n - 1;
		if (i < 0 || i > 1)
			i = mv_rn(2);
		n = i + 1;
		ed = mv_ed + n;
		mv_sethost(i);
		printf("C\t%s\t%d\n", mv_opname[op], n);
		mv_snap();
		if (op == MV_CNT)
			SV_Physics_ClientEntity_NoThink(ed);
		else if (op == MV_CMOVE)
			SV_Physics_ClientMove();
		else if (op == MV_CPRE)
			SV_Physics_ClientEntity_PreThink(ed);
		else if (op == MV_CPOST)
			SV_Physics_ClientEntity_PostThink(ed);
		else
			SV_Physics_ClientEntity(ed);
		mv_end("-");
		break;
	case MV_PM:
		f = mv_rn(3) ? (float)sv.frametime : tv_frand(0.001f, 0.2f);
		printf("C\tPM\t%d", n);
		tv_pf(f);
		printf("\n");
		mv_snap();
		k = mv_qcblocked;
		VectorCopy(PRVM_serveredictvector(ed, origin), w);
		SV_PushMove(ed, f);
		if (mv_qcblocked > k)
			mv_pmblocked++;
		if (!VectorCompare(PRVM_serveredictvector(ed, origin), w))
			mv_pmmoved++;
		mv_end("-");
		break;
	case MV_PP:
		printf("C\tPP\t%d\n", n);
		mv_snap();
		SV_Physics_Pusher(ed);
		mv_end("-");
		break;
	case MV_PHYS:
		printf("C\tPHYS\n");
		mv_snap();
		SV_Physics();
		mv_end("-");
		break;
	case MV_CLIP:
		r = mv_rn(10);
		if (r < 6)
			VectorSet(v, tv_frand(-500, 500), tv_frand(-500, 500), tv_frand(-500, 500));
		else
			VectorSet(v, tv_frand(-0.5f, 0.5f), tv_frand(-400, 400), tv_frand(-0.5f, 0.5f));
		r = mv_rn(10);
		if (r < 6)
			tv_randnormal(w);
		else if (r < 8)
			VectorSet(w, 0, 0, 1);
		else
			VectorSet(w, (float)(mv_rn(3) - 1), 0, 0);
		r = mv_rn(4);
		f = r == 0 ? 1 : r == 1 ? 1.5f : r == 2 ? 2 : tv_frand(1, 2);
		printf("C\tCLIP");
		tv_pv(v);
		tv_pv(w);
		tv_pf(f);
		printf("\n");
		mv_snap();
		{
			prvm_vec3_t in, out;
			VectorCopy(v, in);
			VectorClear(out);
			ClipVelocity(in, w, out, f);
			mv_vstr(s1, out);
		}
		mv_end(s1);
		break;
	case MV_AVF:
		VectorSet(v, tv_frand(-90, 90), tv_frand(-360, 360), mv_rn(2) ? 0 : tv_frand(-180, 180));
		k = 1 + mv_rn(7);
		printf("C\tAVF");
		tv_pv(v);
		printf("\t%d\n", k);
		mv_snap();
		{
			vec3_t fw = {0, 0, 0}, lf = {0, 0, 0}, up = {0, 0, 0};
			AngleVectorsFLU(v, (k & 1) ? fw : NULL, (k & 2) ? lf : NULL, (k & 4) ? up : NULL);
			mv_vstr(s1, fw);
			mv_vstr(s2, lf);
			mv_vstr(s3, up);
		}
		sprintf(ret, "%s\t%s\t%s", s1, s2, s3);
		mv_end(ret);
		break;
	}
}

// ---- configurations
static void mv_config_engine(void) // the values sv_main.c / collision.c register the cvars with
{
	MV_SETCV(collision_extendmovelength, 16);
	MV_SETCV(sv_areagrid_mingridsize, 128);
	MV_SETCV(sv_debugmove, 0);
	MV_SETCV(sv_areadebug, 0);
	MV_SETCV(sv_gameplayfix_swiminbmodels, 1);
	MV_SETCV(sv_legacy_bbox_expand, 1);
	MV_SETCV(developer_extra, 0);
	MV_SETCV(sv_maxvelocity, 2000);
	MV_SETCV(sv_gravity, 800);
	MV_SETCV(sv_stepheight, 18);
	MV_SETCV(sv_nostep, 0);
	MV_SETCV(sv_jumpstep, 0);
	MV_SETCV(sv_wallfriction, 1);
	MV_SETCV(sv_freezenonclients, 0);
	MV_SETCV(sv_gameplayfix_multiplethinksperframe, 1);
	MV_SETCV(sv_gameplayfix_nogravityonground, 0);
	MV_SETCV(sv_gameplayfix_gravityunaffectedbyticrate, 0);
	MV_SETCV(sv_gameplayfix_easierwaterjump, 1);
	MV_SETCV(sv_gameplayfix_nudgeoutofsolid, 0);
	MV_SETCV(sv_gameplayfix_nudgeoutofsolid_separation, 0.03125f);
	MV_SETCV(sv_gameplayfix_unstickplayers, 1);
	MV_SETCV(sv_gameplayfix_stepmultipletimes, 0);
	MV_SETCV(sv_gameplayfix_downtracesupportsongroundflag, 1);
	MV_SETCV(sv_gameplayfix_stepdown, 0);
	MV_SETCV(sv_gameplayfix_fixedcheckwatertransition, 1);
	MV_SETCV(sv_gameplayfix_upwardvelocityclearsongroundflag, 1);
	MV_SETCV(sv_gameplayfix_noairborncorpse, 1);
	MV_SETCV(sv_gameplayfix_noairborncorpse_allowsuspendeditems, 1);
	MV_SETCV(sv_gameplayfix_unstickentities, 1);
	MV_SETCV(sv_gameplayfix_slidemoveprojectiles, 1);
	MV_SETCV(sv_gameplayfix_grenadebouncedownslopes, 1);
	MV_SETCV(sv_gameplayfix_delayprojectiles, 1);
	MV_SETCV(sv_gameplayfix_consistentplayerprethink, 0);
}
static void mv_config_xonotic(void) // xonotic-server.cfg and physicsX.cfg on top of the engine values
{
	mv_config_engine();
	MV_SETCV(sv_maxvelocity, 1000000000);
	MV_SETCV(sv_gameplayfix_delayprojectiles, 0);
	MV_SETCV(sv_gameplayfix_stepmultipletimes, 1);
	MV_SETCV(sv_gameplayfix_stepdown, 2);
	MV_SETCV(sv_gameplayfix_consistentplayerprethink, 1);
	MV_SETCV(sv_gameplayfix_gravityunaffectedbyticrate, 1);
	MV_SETCV(sv_gameplayfix_nogravityonground, 1);
	MV_SETCV(sv_jumpstep, 1);
	MV_SETCV(sv_gravity, 800);
	MV_SETCV(sv_stepheight, 31);
}

// ---- case groups
static void mv_unitcases(int calls)
{
	static const int w[][2] =
	{
		{MV_TEP, 6}, {MV_CCT, 3}, {MV_CV, 6}, {MV_RT, 6}, {MV_IMP, 4}, {MV_FLY, 22}, {MV_GRAV, 2}, {MV_NPK, 5},
		{MV_PE, 10}, {MV_UNO, 4}, {MV_UN, 3}, {MV_CS, 4}, {MV_CW, 6}, {MV_WF, 4}, {MV_WM, 20}, {MV_FOL, 4},
		{MV_CWT, 5}, {MV_TOSS, 14}, {MV_STEP, 9}, {MV_PENT, 14}, {MV_CNT, 8}, {MV_CMOVE, 2}, {MV_CPRE, 2},
		{MV_CPOST, 2}, {MV_CENT, 8}, {MV_PM, 3}, {MV_PP, 3},
	};
	int i, k, total = 0, r, op, n;
	for (k = 0; k < (int)(sizeof(w) / sizeof(w[0])); k++)
		total += w[k][1];
	mv_population(MV_DYN0, 44);
	for (i = 0; i < calls; i++)
	{
		if (i % 12 == 11) // renew a few entities
		{
			for (k = 0; k < 4; k++)
			{
				n = MV_DYN0 + mv_rn(44);
				mv_makeent(n, mv_randmovetype());
				mv_commit(n);
			}
			mv_makeclient(mv_rn(2));
		}
		r = mv_rn(total);
		for (k = 0; r >= w[k][1]; k++)
			r -= w[k][1];
		op = w[k][0];
		if (mv_rn(10) < 7 && (n = mv_freshfor(op)) >= 0)
			mv_call(op, n);
		else
			mv_call(op, mv_pickent());
	}
}
static void mv_pushcases(int scenes)
{
	int s, n, i, end;
	for (s = 0; s < scenes; s++)
	{
		mv_makeclient(0);
		mv_makeclient(1);
		end = mv_pushscene(MV_DYN0);
		for (n = end; n < MV_SENT; n++)
			if (!mv_priv[n].free)
				mv_setfree(n, 1);
		mv_call(MV_PM, MV_DYN0);
		for (i = 0; i < 3; i++)
			mv_call(MV_PP, MV_DYN0);
		mv_call(MV_PENT, MV_DYN0);
		// the riders on their own after the push
		for (i = 0; i < 3; i++)
		{
			n = MV_DYN0 + 1 + mv_rn(end - MV_DYN0 - 1);
			if (!mv_priv[n].free)
				mv_call(mv_rn(2) ? MV_PENT : MV_TOSS, n);
		}
	}
}
static void mv_frames(int nframes, int nents)
{
	int f, end, n;
	mv_makeclient(0);
	mv_makeclient(1);
	end = mv_pushscene(MV_DYN0);
	for (n = end; n < MV_SENT; n++)
	{
		if (n < end + nents)
		{
			mv_makeent(n, mv_randmovetype());
			mv_commit(n);
		}
		else if (!mv_priv[n].free)
			mv_setfree(n, 1);
	}
	for (f = 0; f < nframes; f++)
		mv_call(MV_PHYS, 0);
}
// paths the random cases may miss: every movetype on a client entity through the client paths, a pusher of
// an unrecognized solid type, an item whose touch function removes it while SV_Physics_Toss moves it
static void mv_edgecases(void)
{
	static const int cmt[16] =
	{
		MOVETYPE_NONE, MOVETYPE_WALK, MOVETYPE_STEP, MOVETYPE_FLY, MOVETYPE_TOSS, MOVETYPE_PUSH, MOVETYPE_NOCLIP,
		MOVETYPE_FLYMISSILE, MOVETYPE_BOUNCE, MOVETYPE_BOUNCEMISSILE, MOVETYPE_FOLLOW, MOVETYPE_FAKEPUSH,
		MOVETYPE_FLY_WORLDONLY, MOVETYPE_PHYSICS, 150, 50,
	};
	prvm_prog_t *prog = SVVM_prog;
	prvm_edict_t *ed;
	int i, k, n;
	for (i = 0; i < 16; i++)
	{
		for (k = 0; k < 2; k++)
		{
			mv_makeclient(0);
			PRVM_serveredictfloat(mv_ed + 1, movetype) = cmt[i];
			mv_clients[0].begun = 1;
			mv_clients[0].clmovement_inputtimeout = k ? 0.05f : 0;
			mv_commit(1);
			mv_printcl("CLS", 0);
			mv_call(MV_CNT, 1);
			mv_call(MV_CENT, 1);
			mv_call(MV_CMOVE, 1);
		}
	}
	n = MV_DYN0 + 44;
	ed = mv_ed + n;
	mv_makeent(n, MOVETYPE_PUSH);
	PRVM_serveredictfloat(ed, solid) = 7;
	VectorSet(PRVM_serveredictvector(ed, velocity), 10, 20, 30);
	mv_commit(n);
	mv_call(MV_PM, n);
	for (i = 0; i < 4; i++)
	{
		n = MV_DYN0 + 45;
		ed = mv_ed + n;
		mv_fresh(n, i < 2 ? MOVETYPE_TOSS : MOVETYPE_BOUNCE, 0, 1);
		PRVM_serveredictfloat(ed, solid) = SOLID_BBOX;
		PRVM_serveredictfloat(ed, flags) = 0;
		PRVM_serveredictfloat(ed, dphitcontentsmask) = 0;
		PRVM_serveredictfunction(ed, touch) = 74;
		PRVM_serveredictvector(ed, velocity)[2] = -1200;
		mv_commit(n);
		mv_call(MV_TOSS, n);
	}
	// bouncing missiles that stop at the first impact (sv_gameplayfix_slidemoveprojectiles 0)
	MV_SETCV(sv_gameplayfix_slidemoveprojectiles, 0);
	for (i = 0; i < 3; i++)
	{
		n = MV_DYN0 + 45;
		ed = mv_ed + n;
		mv_fresh(n, MOVETYPE_BOUNCEMISSILE, 0, 4);
		PRVM_serveredictfloat(ed, solid) = SOLID_BBOX;
		PRVM_serveredictfloat(ed, flags) = 0;
		PRVM_serveredictfloat(ed, dphitcontentsmask) = 0;
		PRVM_serveredictfunction(ed, touch) = 0;
		PRVM_serveredictvector(ed, velocity)[2] = -1500;
		mv_commit(n);
		mv_call(MV_TOSS, n);
	}
	MV_SETCV(sv_gameplayfix_slidemoveprojectiles, 1);
	// walking off the low bump: the step down lands on the floor, whose impact runs a touch that teleports
	for (i = 0; i < 4; i++)
	{
		float d[3];
		n = MV_DYN0 + 46;
		ed = mv_ed + n;
		mv_fresh(n, MOVETYPE_WALK, 0, 0);
		VectorSet(PRVM_serveredictvector(ed, origin), 1250 + tv_frand(-36, 36), 250 + tv_frand(-36, 36), 10 + 24 + 0.03125f);
		VectorSet(d, PRVM_serveredictvector(ed, origin)[0] - 1250, PRVM_serveredictvector(ed, origin)[1] - 250, 0);
		VectorNormalize(d);
		VectorScale(d, tv_frand(250, 450), PRVM_serveredictvector(ed, velocity));
		PRVM_serveredictfloat(ed, solid) = SOLID_SLIDEBOX;
		PRVM_serveredictfloat(ed, flags) = FL_ONGROUND;
		PRVM_serveredictedict(ed, groundentity) = MV_SCENE0 + 15;
		PRVM_serveredictfloat(ed, dphitcontentsmask) = 0;
		PRVM_serveredictfloat(ed, watertype) = 0;
		PRVM_serveredictfloat(ed, waterlevel) = 0;
		PRVM_serveredictfunction(ed, touch) = i < 3 ? 75 : 0;
		mv_commit(n);
		mv_call(MV_WM, n);
	}
	// running up the stairs without sv_gameplayfix_stepmultipletimes: the step up runs into the next stair
	// (SV_WallFriction), and falling into the corner of the walls without a step height (a crease of 3 planes)
	MV_SETCV(sv_gameplayfix_stepmultipletimes, 0);
	for (i = 0; i < 8; i++)
	{
		n = MV_DYN0 + 46;
		ed = mv_ed + n;
		mv_fresh(n, MOVETYPE_WALK, 3, 0);
		PRVM_serveredictvector(ed, velocity)[0] = tv_frand(900, 1500);
		PRVM_serveredictfloat(ed, solid) = SOLID_SLIDEBOX;
		PRVM_serveredictfloat(ed, flags) = FL_ONGROUND;
		PRVM_serveredictedict(ed, groundentity) = MV_SCENE0;
		PRVM_serveredictfloat(ed, dphitcontentsmask) = 0;
		PRVM_serveredictfunction(ed, touch) = 0;
		mv_commit(n);
		mv_call(MV_WM, n);
	}
	MV_SETCV(sv_gameplayfix_stepmultipletimes, 1);
	for (i = 0; i < 8; i++)
	{
		n = MV_DYN0 + 46;
		ed = mv_ed + n;
		mv_fresh(n, MOVETYPE_STEP, 2, 0);
		VectorSet(PRVM_serveredictvector(ed, velocity), tv_frand(600, 1500), tv_frand(600, 1500), -tv_frand(300, 900));
		PRVM_serveredictvector(ed, origin)[2] += tv_frand(0, 4);
		PRVM_serveredictfloat(ed, solid) = SOLID_SLIDEBOX;
		PRVM_serveredictfloat(ed, flags) = 0;
		PRVM_serveredictfloat(ed, dphitcontentsmask) = 0;
		PRVM_serveredictfunction(ed, touch) = 0;
		mv_commit(n);
		printf("C\tFLY\t%d", n);
		tv_pf((float)sv.frametime);
		printf("\t1\t1\t%d", SV_GenericHitSuperContentsMask(ed));
		tv_pf(0);
		printf("\n");
		mv_snap();
		{
			float sn[3] = {0, 0, 0};
			char s1[64], ret[128];
			k = SV_FlyMove(ed, (float)sv.frametime, true, sn, SV_GenericHitSuperContentsMask(ed), 0, 0, 0);
			mv_flyblocked[k & 15]++;
			mv_vstr(s1, sn);
			sprintf(ret, "%d\t%s", k, s1);
			mv_end(ret);
		}
	}
	// an entity spawned during the frame below the spawner's number gets its move in the second pass
	// (sv_gameplayfix_delayprojectiles < 0)
	MV_SETCV(sv_gameplayfix_delayprojectiles, -1);
	n = MV_SENT - 1;
	ed = mv_ed + n;
	mv_clearent(n);
	PRVM_serveredictfloat(ed, solid) = SOLID_NOT;
	PRVM_serveredictfunction(ed, think) = 10;
	PRVM_serveredictfloat(ed, nextthink) = (float)sv.time;
	VectorSet(PRVM_serveredictvector(ed, origin), 1300, 300, 300);
	mv_priv[n].move = true;
	mv_commit(n);
	for (i = MV_DYN0; i < MV_SENT - 1 && !mv_priv[i].free; i++)
		;
	if (i == MV_SENT - 1)
		mv_setfree(MV_DYN0 + 40, 1);
	mv_call(MV_PHYS, 0);
	MV_SETCV(sv_gameplayfix_delayprojectiles, 0);
}
// single calls of the movers a cvar variant changes, on entities set up for them
static void mv_variantcalls(void)
{
	static const int ops[6] = {MV_WM, MV_WM, MV_TOSS, MV_FLY, MV_STEP, MV_PENT};
	int i, op;
	for (i = 0; i < 90; i++)
	{
		op = ops[mv_rn(6)];
		mv_call(op, mv_freshfor(op));
	}
}

int main(void)
{
	prvm_prog_t *prog = SVVM_prog;
	int i, k;
	setvbuf(stdout, NULL, _IOLBF, 0); // a crash keeps every finished line (the workflow log shows the last ones)
	tv_seed = 20261129u;

	// what Collision_Init / Mod_BrushInit would have set by registering the cvars
	collision_impactnudge.value = 0.03125f;
	collision_triangle_axialsides.integer = 1;
	mod_q3bsp_curves_collisions.integer = 1;
	mod_q3bsp_optimizedtraceline.integer = 1;
	mod_collision_bih.integer = 1;
	sv_sound_land.string = ""; // xonotic-server.cfg
	sv_sound_watersplash.string = "";
	mv_config_xonotic();

	tv_maketextures();
	tv_makebrushes();
	tv_makesurfaces();
	tv_makebsp();
	tv_makemodels();
	mv_setupprog();
	mv_setupserver();
	svs.maxclients = 2;
	svs.clients = mv_clients;
	printf("SVS\t%d\n", svs.maxclients);
	mv_setframetime((double)0.0333333f); // Xonotic's sys_ticrate (xonotic-common.cfg)
	mv_scene();

	for (i = 0; i < 80; i++)
		mv_call(MV_AVF, 0);
	for (i = 0; i < 150; i++)
		mv_call(MV_CLIP, 0);

	// single calls on random entities: Xonotic's configuration, then the engine's own
	mv_unitcases(700);
	mv_pushcases(70);
	mv_edgecases();
	mv_config_engine();
	mv_setframetime((double)0.0138889f); // the engine's sys_ticrate default
	MV_SETCV(developer_extra, 1);
	mv_unitcases(500);
	MV_SETCV(developer_extra, 0);
	mv_pushcases(40);

	// whole server frames
	mv_config_xonotic();
	mv_setframetime((double)0.0333333f);
	for (k = 0; k < 3; k++)
		mv_frames(30, 34);
	mv_setframetime((double)0.0138889f);
	mv_frames(36, 34);
	mv_config_engine();
	mv_frames(30, 34);
	mv_setframetime((double)0.0333333f);
	mv_frames(24, 30);
	// cvar variants (on top of Xonotic's configuration)
	mv_config_xonotic();
	MV_SETCV(sv_gameplayfix_consistentplayerprethink, 0);
	MV_SETCV(sv_gameplayfix_delayprojectiles, -1);
	MV_SETCV(sv_gameplayfix_nudgeoutofsolid, 1);
	MV_SETCV(sv_gameplayfix_stepdown, 1);
	mv_frames(24, 30);
	mv_variantcalls();
	mv_config_xonotic();
	MV_SETCV(sv_gameplayfix_gravityunaffectedbyticrate, 0);
	MV_SETCV(sv_gameplayfix_nogravityonground, 0);
	MV_SETCV(sv_gameplayfix_stepmultipletimes, 0);
	MV_SETCV(sv_jumpstep, 0);
	MV_SETCV(sv_gameplayfix_multiplethinksperframe, 0);
	MV_SETCV(sv_gameplayfix_fixedcheckwatertransition, 0);
	MV_SETCV(sv_gameplayfix_unstickentities, 0);
	MV_SETCV(sv_gameplayfix_slidemoveprojectiles, 0);
	MV_SETCV(sv_gameplayfix_grenadebouncedownslopes, 0);
	MV_SETCV(sv_gameplayfix_noairborncorpse, 0);
	mv_frames(24, 30);
	mv_variantcalls();
	mv_config_xonotic();
	MV_SETCV(sv_gameplayfix_upwardvelocityclearsongroundflag, 0);
	MV_SETCV(sv_gameplayfix_easierwaterjump, 0);
	MV_SETCV(sv_gameplayfix_noairborncorpse_allowsuspendeditems, 0);
	MV_SETCV(sv_gameplayfix_unstickplayers, 0);
	MV_SETCV(sv_gameplayfix_downtracesupportsongroundflag, 0);
	MV_SETCV(sv_wallfriction, 0);
	MV_SETCV(sv_gameplayfix_nudgeoutofsolid, 1);
	MV_SETCV(sv_gameplayfix_nudgeoutofsolid_separation, -1);
	mv_frames(24, 30);
	mv_variantcalls();
	MV_SETCV(sv_gameplayfix_nudgeoutofsolid_separation, 0.03125f);
	mv_variantcalls();
	mv_config_xonotic();
	MV_SETCV(sv_nostep, 1);
	MV_SETCV(sv_freezenonclients, 1);
	mv_frames(8, 20);
	mv_variantcalls();
	MV_SETCV(sv_freezenonclients, 0);
	// force_retouch, no EndFrame, and the highest edicts freed (prog->num_edicts goes down)
	mv_config_xonotic();
	mv_makeclient(0);
	mv_makeclient(1);
	PRVM_serverglobalfloat(force_retouch) = 2;
	printf("GSET\t%d\t%08x\n", prog->globaloffsets.force_retouch, tv_bits(PRVM_serverglobalfloat(force_retouch)));
	mv_frames(6, 30);
	prog->funcoffsets.EndFrame = 0;
	printf("FUNC\tEndFrame\t0\n");
	for (i = MV_SENT; i > MV_SENT - 12; i--)
		if (!mv_priv[i].free)
			mv_setfree(i, 1);
	mv_setfree(MV_SENT, 1);
	for (i = 0; i < 6; i++)
		mv_call(MV_PHYS, 0);
	prog->num_edicts = MV_NED;
	printf("NUMED\t%d\n", prog->num_edicts);
	prog->funcoffsets.EndFrame = MV_FN_END;
	printf("FUNC\tEndFrame\t%d\n", MV_FN_END);

	// what the cases reached
	for (i = 0; i < MV_NOPS; i++)
		printf("COUNT\tcalls\t%s\t%d\n", mv_opname[i], mv_calls[i]);
	printf("COUNT\tqc\tthink %d touch %d blocked %d contentstransition %d landevent %d frame %d other %d\n", mv_qcthink, mv_qctouch, mv_qcblocked, mv_qctransition, mv_qcland, mv_qcframe, mv_qcother);
	printf("COUNT\tSV_FlyMove blocked");
	for (i = 0; i < 16; i++)
		printf(" %d:%d", i, mv_flyblocked[i]);
	printf(" stepnormal-set:%d\n", mv_flystep);
	printf("COUNT\tSV_PushEntity false %d worldstartsolid %d; setorigin teleports %d\n", mv_pefalse, mv_peworldstuck, mv_teleports);
	printf("COUNT\tSV_PushMove blocked-calls %d moved %d\n", mv_pmblocked, mv_pmmoved);
	printf("COUNT\tSV_UnstickEntityReturnOffset stuck %d good %d unstuck %d\n", mv_unstick[0], mv_unstick[1], mv_unstick[2]);
	printf("COUNT\tSV_CheckWater waterlevel 0:%d 1:%d 2:%d 3:%d\n", mv_waterlevels[0], mv_waterlevels[1], mv_waterlevels[2], mv_waterlevels[3]);
	printf("COUNT\tSV_WalkMove up %d down %d unmoved %d\n", mv_wmup, mv_wmdown, mv_wmrevert);
	printf("COUNT\tSV_Physics_Toss onground %d bounced %d\n", mv_tosslanded, mv_tossbounced);
	printf("COUNT\tSV_ClientThink %d\n", mv_clientthinkcount);
	printf("END\n");
	return 0;
}
