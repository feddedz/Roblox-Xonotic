// Reference vectors for engine/sv_move.luau (all of sv_move.c), the world builtins of engine/svvm_cmds.luau
// (setorigin, setsize, traceline, tracebox, tracetoss with SV_Trace_Toss, findradius, walkmove, droptofloor,
// checkbottom, pointcontents, copyentity), VM_SetTraceGlobals / VM_changeyaw of engine/prvm_cmds.luau and the
// SVVM_begin_increase_edicts / SVVM_end_increase_edicts / SVVM_free_edict hooks of engine/sv_main.luau: the
// release's files compiled unchanged (svmove_vectors.sh). This file is compiled four times:
//   -DSMV_PART_SVVM    svvm_cmds.c, plus wrappers that make its static builtins callable
//   -DSMV_PART_SVMAIN  sv_main.c, plus wrappers for its static SVVM_* edict hooks
//   -DSMV_PART_SVMOVE  sv_move.c, plus wrappers for its static SV_StepDirection .. SV_CloseEnough
//   (none)             the driver: svphys_vectors.c is included as it is (its world model, submodel, server
//                      setup and the stubs of the unlinked engine parts); its main() never runs, the driver
//                      runs from a constructor and exits.
// prvm_cmds.c is linked (VM_Warning, VM_SetTraceGlobals, VM_changeyaw) with the three frame / skeleton
// functions svphys_vectors.c stubs renamed on the command line.
// Every call is preceded by the state the generator changed (E: edict state words, GS: globals, S: srand seed)
// and followed by everything it changed: TOUCH (QC touch calls with every global), ERR (prog->error_cmd),
// RV (return value), D (changed edict state words), GL (changed globals), CY (c_yes / c_no increments).
// An edict's state words: 0 free, 1 suspendedinairflag, 2 mark, 3-5 areamins, 6-8 areamaxs, 9.. its fields.
// Floats are printed as bit patterns, doubles as 64-bit patterns. Names here start with smv_ / SMV_.

#if defined(SMV_PART_SVVM)
#include "svvm_cmds.c"
void smv_vm_setorigin(prvm_prog_t *prog) { VM_SV_setorigin(prog); }
void smv_vm_setsize(prvm_prog_t *prog) { VM_SV_setsize(prog); }
void smv_vm_traceline(prvm_prog_t *prog) { VM_SV_traceline(prog); }
void smv_vm_tracebox(prvm_prog_t *prog) { VM_SV_tracebox(prog); }
void smv_vm_tracetoss(prvm_prog_t *prog) { VM_SV_tracetoss(prog); }
void smv_vm_findradius(prvm_prog_t *prog) { VM_SV_findradius(prog); }
void smv_vm_walkmove(prvm_prog_t *prog) { VM_SV_walkmove(prog); }
void smv_vm_droptofloor(prvm_prog_t *prog) { VM_SV_droptofloor(prog); }
void smv_vm_checkbottom(prvm_prog_t *prog) { VM_SV_checkbottom(prog); }
void smv_vm_pointcontents(prvm_prog_t *prog) { VM_SV_pointcontents(prog); }
void smv_vm_copyentity(prvm_prog_t *prog) { VM_SV_copyentity(prog); }

#elif defined(SMV_PART_SVMAIN)
#include "sv_main.c"
void smv_begin_increase_edicts(prvm_prog_t *prog) { SVVM_begin_increase_edicts(prog); }
void smv_end_increase_edicts(prvm_prog_t *prog) { SVVM_end_increase_edicts(prog); }
void smv_free_edict(prvm_prog_t *prog, prvm_edict_t *ed) { SVVM_free_edict(prog, ed); }

#elif defined(SMV_PART_SVMOVE)
#include "sv_move.c"
qboolean smv_StepDirection(prvm_edict_t *ent, float yaw, float dist) { return SV_StepDirection(ent, yaw, dist); }
void smv_FixCheckBottom(prvm_edict_t *ent) { SV_FixCheckBottom(ent); }
void smv_NewChaseDir(prvm_edict_t *actor, prvm_edict_t *enemy, float dist) { SV_NewChaseDir(actor, enemy, dist); }
qboolean smv_CloseEnough(prvm_edict_t *ent, prvm_edict_t *goal, float dist) { return SV_CloseEnough(ent, goal, dist); }

#else
#include "svphys_vectors.c"
#include <setjmp.h>
#include <stdarg.h>

// ---- the wrappers of the other parts
void smv_vm_setorigin(prvm_prog_t *prog);
void smv_vm_setsize(prvm_prog_t *prog);
void smv_vm_traceline(prvm_prog_t *prog);
void smv_vm_tracebox(prvm_prog_t *prog);
void smv_vm_tracetoss(prvm_prog_t *prog);
void smv_vm_findradius(prvm_prog_t *prog);
void smv_vm_walkmove(prvm_prog_t *prog);
void smv_vm_droptofloor(prvm_prog_t *prog);
void smv_vm_checkbottom(prvm_prog_t *prog);
void smv_vm_pointcontents(prvm_prog_t *prog);
void smv_vm_copyentity(prvm_prog_t *prog);
void smv_begin_increase_edicts(prvm_prog_t *prog);
void smv_end_increase_edicts(prvm_prog_t *prog);
void smv_free_edict(prvm_prog_t *prog, prvm_edict_t *ed);
qboolean smv_StepDirection(prvm_edict_t *ent, float yaw, float dist);
void smv_FixCheckBottom(prvm_edict_t *ent);
void smv_NewChaseDir(prvm_edict_t *actor, prvm_edict_t *enemy, float dist);
qboolean smv_CloseEnough(prvm_edict_t *ent, prvm_edict_t *goal, float dist);
extern int c_yes, c_no; // sv_move.c

// ---- what prvm_cmds.c needs from the parts of the engine that are not linked
cvar_t prvm_backtraceforwarnings = {0, "prvm_backtraceforwarnings", "0", "VM_Warning prints a backtrace"}; // prvm_edict.c, 0
#undef vsnprintf
int dpvsnprintf(char *buffer, size_t buffersize, const char *format, va_list args) // common.c
{
	int result = vsnprintf(buffer, buffersize, format, args);
	if (result < 0 || (size_t)result >= buffersize)
	{
		buffer[buffersize - 1] = '\0';
		return -1;
	}
	return result;
}
// prvm_edict.c: VM_SetTraceGlobals stores the hit texture's name as a tempstring; the name is printed
#define SMV_NTS 4096
#define SMV_TS0 0x100000
static char smv_ts[SMV_NTS][64];
static int smv_tsn;
int PRVM_SetTempString(prvm_prog_t *prog, const char *s)
{
	int k;
	(void)prog;
	if (!s)
		return 0;
	k = smv_tsn++ % SMV_NTS;
	strlcpy(smv_ts[k], s, sizeof(smv_ts[k]));
	return SMV_TS0 + k;
}

// ---- the prog
#define SMV_NED 64
#define SMV_NF 56
#define SMV_G0 28
#define SMV_NG 50
#define SMV_NS (9 + SMV_NF)
#define SMV_A0 25 // actors SMV_A0 .. SMV_A0 + SMV_NA - 1
#define SMV_NA 30
#define SMV_ENEMY 55 // an origin for flyers' enemies (never linked)
#define SMV_GOAL 56 // the goal of chasers (a linked trigger without touch function)
#define SMV_FREE0 57 // 57 .. 59 are free
#define SMV_SCR0 60 // 60 .. 63: copyentity / free_edict targets
static prvm_edict_t smv_ed[SMV_NED];
static edict_engineprivate_t smv_priv[SMV_NED];
static prvm_vec_t smv_fields[SMV_NED * SMV_NF];
static prvm_vec_t smv_globals[SMV_NG];
static mfunction_t smv_xfunction;
static int smv_chain2; // a second chain field for findradius(org, rad, chainfield)
static int smv_gtex; // the global slot of trace_dphittexturename
static jmp_buf smv_jb;

#define SMV_SETCV(v, x) do { (v).value = (float)(x); (v).integer = (int)(v).value; printf("CVAR\t%s\t%.9g\n", (v).name, (double)(v).value); } while (0)
#define SMV_ED(n) (smv_ed + (n))

// prog->error_cmd: the message (newlines and tabs escaped) and a longjmp back out of the call
static void smv_error(const char *fmt, ...)
{
	char buf[2048];
	const char *p;
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	printf("ERR\t");
	for (p = buf; *p; p++)
	{
		if (*p == '\n')
			printf("\\n");
		else if (*p == '\t')
			printf("\\t");
		else
			putchar(*p);
	}
	printf("\n");
	longjmp(smv_jb, 1);
}
// prog->ExecuteProgram: the touch function calls of SV_LinkEdict_TouchAreaGrid_Call, with every global
static void smv_execute(prvm_prog_t *prog, func_t fnum, const char *errormessage)
{
	int i;
	(void)errormessage;
	printf("TOUCH\t%d", (int)fnum);
	for (i = 0; i < SMV_NG; i++)
		printf("\t%08x", (unsigned)prog->globals.ip[i]);
	printf("\n");
}

static void smv_setupprog(void)
{
	prvm_prog_t *prog = SVVM_prog;
	int ofs = 1, i;
	memset(prog, 0, sizeof(*prog));
#define SMV_F(name, n) do { prog->fieldoffsets.name = ofs; printf("FIELD\t%s\t%d\n", #name, ofs); ofs += (n); } while (0)
	SMV_F(owner, 1);
	SMV_F(solid, 1);
	SMV_F(flags, 1);
	SMV_F(mins, 3);
	SMV_F(maxs, 3);
	SMV_F(size, 3);
	SMV_F(origin, 3);
	SMV_F(angles, 3);
	SMV_F(modelindex, 1);
	SMV_F(dphitcontentsmask, 1);
	SMV_F(pflags, 1);
	SMV_F(movetype, 1);
	SMV_F(avelocity, 3);
	SMV_F(absmin, 3);
	SMV_F(absmax, 3);
	SMV_F(touch, 1);
	SMV_F(frame, 1);
	SMV_F(effects, 1);
	SMV_F(velocity, 3);
	SMV_F(gravity, 1);
	SMV_F(ideal_yaw, 1);
	SMV_F(yaw_speed, 1);
	SMV_F(enemy, 1);
	SMV_F(goalentity, 1);
	SMV_F(groundentity, 1);
	SMV_F(chain, 1);
	SMV_F(model, 1);
	SMV_F(takedamage, 1);
	SMV_F(colormap, 1);
	SMV_F(skin, 1);
	SMV_F(nextthink, 1);
	SMV_F(classname, 1);
#undef SMV_F
	smv_chain2 = ofs;
	printf("FIELD\tchain2\t%d\n", ofs);
	ofs++;
	if (ofs > SMV_NF)
	{
		printf("too many fields\n");
		exit(1);
	}
	printf("NFIELDS\t%d\n", SMV_NF);
	ofs = SMV_G0;
#define SMV_G(name, n) do { prog->globaloffsets.name = ofs; printf("GLOBAL\t%s\t%d\n", #name, ofs); ofs += (n); } while (0)
	SMV_G(self, 1);
	SMV_G(other, 1);
	SMV_G(time, 1);
	SMV_G(trace_allsolid, 1);
	SMV_G(trace_startsolid, 1);
	SMV_G(trace_fraction, 1);
	SMV_G(trace_inwater, 1);
	SMV_G(trace_inopen, 1);
	SMV_G(trace_endpos, 3);
	SMV_G(trace_plane_normal, 3);
	SMV_G(trace_plane_dist, 1);
	SMV_G(trace_ent, 1);
	SMV_G(trace_dpstartcontents, 1);
	SMV_G(trace_dphitcontents, 1);
	SMV_G(trace_dphitq3surfaceflags, 1);
	SMV_G(trace_dphittexturename, 1);
#undef SMV_G
	smv_gtex = prog->globaloffsets.trace_dphittexturename;
	printf("NGLOBALS\t%d\n", SMV_NG);
	prog->entityfields = SMV_NF;
	prog->entityfieldsarea = SMV_NF * SMV_NED;
	prog->edictsfields = smv_fields;
	prog->edicts = smv_ed;
	prog->max_edicts = SMV_NED;
	prog->num_edicts = SMV_NED;
	prog->limit_edicts = SMV_NED;
	prog->globals.fp = smv_globals;
	prog->name = "server";
	prog->ExecuteProgram = smv_execute;
	prog->error_cmd = smv_error;
	prog->xfunction = &smv_xfunction;
	for (i = 0; i < SMV_NED; i++)
	{
		smv_ed[i].priv.server = smv_priv + i;
		smv_ed[i].fields.fp = smv_fields + i * SMV_NF;
	}
	printf("NED\t%d\n", SMV_NED);
}

// ---- state sync: what the generator changed goes out before a call, what the call changed after it
static uint32_t smv_sync[SMV_NED][SMV_NS], smv_gsync[SMV_NG];
static uint32_t smv_pre[SMV_NED][SMV_NS], smv_gpre[SMV_NG];
static int smv_cy0, smv_cn0;
static void smv_state(int n, uint32_t *s)
{
	const edict_engineprivate_t *p = smv_priv + n;
	s[0] = (uint32_t)p->free;
	s[1] = (uint32_t)p->suspendedinairflag;
	s[2] = (uint32_t)p->mark;
	memcpy(s + 3, p->areamins, 12);
	memcpy(s + 6, p->areamaxs, 12);
	memcpy(s + 9, smv_fields + n * SMV_NF, SMV_NF * 4);
}
static uint32_t smv_gword(int i)
{
	uint32_t u;
	memcpy(&u, smv_globals + i, 4);
	return u;
}
static void smv_flush(void)
{
	uint32_t s[SMV_NS];
	int n, i, any;
	for (n = 0; n < SMV_NED; n++)
	{
		smv_state(n, s);
		any = 0;
		for (i = 0; i < SMV_NS; i++)
		{
			if (i >= 3 && i < 9)
				continue; // the area: only linking changes it (LINK / the calls)
			if (s[i] != smv_sync[n][i])
			{
				if (!any)
					printf("E\t%d", n);
				any = 1;
				printf("\t%d:%08x", i, s[i]);
			}
		}
		if (any)
			printf("\n");
		memcpy(smv_sync[n], s, sizeof(s));
	}
	any = 0;
	for (i = 0; i < SMV_NG; i++)
	{
		if (i == smv_gtex)
			continue;
		if (smv_gword(i) != smv_gsync[i])
		{
			if (!any)
				printf("GS");
			any = 1;
			printf("\t%d:%08x", i, smv_gword(i));
		}
		smv_gsync[i] = smv_gword(i);
	}
	if (any)
		printf("\n");
}
static void smv_begin(void)
{
	prvm_prog_t *prog = SVVM_prog;
	smv_flush();
	memcpy(smv_pre, smv_sync, sizeof(smv_pre));
	memcpy(smv_gpre, smv_gsync, sizeof(smv_gpre));
	smv_cy0 = c_yes;
	smv_cn0 = c_no;
	prog->xfunction = &smv_xfunction;
}
static void smv_end(void)
{
	uint32_t s[SMV_NS], g;
	int n, i, any;
	for (n = 0; n < SMV_NED; n++)
	{
		smv_state(n, s);
		any = 0;
		for (i = 0; i < SMV_NS; i++)
		{
			if (s[i] != smv_pre[n][i])
			{
				if (!any)
					printf("D\t%d", n);
				any = 1;
				printf("\t%d:%08x", i, s[i]);
			}
		}
		if (any)
			printf("\n");
		memcpy(smv_sync[n], s, sizeof(s));
	}
	printf("GL");
	for (i = 0; i < SMV_NG; i++)
	{
		g = smv_gword(i);
		if (i == smv_gtex)
		{
			if (g >= SMV_TS0 && g < SMV_TS0 + SMV_NTS)
				printf("\t%d:s:%s", i, smv_ts[g - SMV_TS0]);
			else
				printf("\t%d:%08x", i, g);
		}
		else if (g != smv_gpre[i])
			printf("\t%d:%08x", i, g);
		smv_gsync[i] = g;
	}
	printf("\nCY\t%d\t%d\n", c_yes - smv_cy0, c_no - smv_cn0);
}
static void smv_seed(void)
{
	unsigned s = tv_rnd() % 100000u;
	printf("S\t%u\n", s);
	srand(s);
}
#define SMV_CALL(stmt) do { if (!setjmp(smv_jb)) { stmt; } } while (0)

// ---- branch counts (printed at the end)
#define SMV_MAXC 300
static const char *smv_cname[SMV_MAXC];
static int smv_cval[SMV_MAXC], smv_nc;
static void smv_count(const char *name)
{
	int i;
	for (i = 0; i < smv_nc; i++)
	{
		if (!strcmp(smv_cname[i], name))
		{
			smv_cval[i]++;
			return;
		}
	}
	if (smv_nc < SMV_MAXC)
	{
		smv_cname[smv_nc] = name;
		smv_cval[smv_nc++] = 1;
	}
}

// ---- edicts
static void smv_clear(int n)
{
	memset(smv_fields + n * SMV_NF, 0, SMV_NF * sizeof(prvm_vec_t));
}
static void smv_link(int n)
{
	prvm_prog_t *prog = SVVM_prog;
	smv_flush();
	printf("LINK\t%d\n", n);
	SV_LinkEdict(SMV_ED(n));
	printf("LK\t%d", n);
	tv_pv(PRVM_serveredictvector(SMV_ED(n), absmin));
	tv_pv(PRVM_serveredictvector(SMV_ED(n), absmax));
	tv_pv(smv_priv[n].areamins);
	tv_pv(smv_priv[n].areamaxs);
	printf("\n");
	smv_state(n, smv_sync[n]);
}
static void smv_setsize(int n, const float *mins, const float *maxs)
{
	prvm_prog_t *prog = SVVM_prog;
	VectorCopy(mins, PRVM_serveredictvector(SMV_ED(n), mins));
	VectorCopy(maxs, PRVM_serveredictvector(SMV_ED(n), maxs));
	VectorSubtract(maxs, mins, PRVM_serveredictvector(SMV_ED(n), size));
}
static void smv_randsize(int n, int big)
{
	static const float sz[6][6] = {
		{-16, -16, -24, 16, 16, 40}, {-16, -16, -24, 16, 16, 45}, {-8, -8, 0, 8, 8, 16},
		{-32, -32, -24, 32, 32, 64}, {0, 0, 0, 0, 0, 0}, {-12, -20, -8, 12, 20, 30}};
	float mins[3], maxs[3];
	int j, r = (int)(tv_rnd() % 8);
	if (r < 6 && (big || r != 3))
	{
		VectorCopy(sz[r], mins);
		VectorCopy(sz[r] + 3, maxs);
	}
	else
	{
		for (j = 0; j < 3; j++)
		{
			mins[j] = -tv_frand(1, 28);
			maxs[j] = tv_frand(1, 36);
		}
	}
	smv_setsize(n, mins, maxs);
}
static int smv_nextactor(void)
{
	static int k;
	return SMV_A0 + (k++ % SMV_NA);
}
// kind 0 walker, 1 flyer, 2 swimmer
static void smv_actor(int n, int kind)
{
	static const float speeds[9] = {0, 5, 10, 20, 45, 90, 180, 360, 720};
	static const int masks[4] = {1, 0x21, 0x201, 0x2000001};
	prvm_prog_t *prog = SVVM_prog;
	prvm_edict_t *ed = SMV_ED(n);
	int fl;
	smv_clear(n);
	PRVM_serveredictfloat(ed, solid) = (tv_rnd() % 5) ? SOLID_SLIDEBOX : SOLID_BBOX;
	PRVM_serveredictfloat(ed, movetype) = kind == 1 ? MOVETYPE_FLY : kind == 2 ? MOVETYPE_STEP : (tv_rnd() % 4 ? MOVETYPE_STEP : MOVETYPE_WALK);
	fl = (tv_rnd() % 3) ? FL_MONSTER : 0;
	if (kind == 0)
		fl |= FL_ONGROUND | ((tv_rnd() % 6) == 0 ? FL_PARTIALGROUND : 0);
	else if (kind == 1)
		fl |= FL_FLY | ((tv_rnd() % 10) == 0 ? FL_SWIM : 0);
	else
		fl |= FL_SWIM | ((tv_rnd() % 10) == 0 ? FL_ONGROUND : 0);
	if ((tv_rnd() % 12) == 0)
		fl |= FL_ITEM;
	PRVM_serveredictfloat(ed, flags) = fl;
	PRVM_serveredictvector(ed, angles)[0] = (tv_rnd() % 6) == 0 ? tv_frand(-30, 30) : 0;
	PRVM_serveredictvector(ed, angles)[1] = (tv_rnd() % 4) == 0 ? (float)(45 * (int)(tv_rnd() % 8)) : tv_frand(-400, 760);
	PRVM_serveredictfloat(ed, ideal_yaw) = (tv_rnd() % 4) == 0 ? (float)(45 * (int)(tv_rnd() % 8)) : tv_frand(-90, 450);
	PRVM_serveredictfloat(ed, yaw_speed) = speeds[tv_rnd() % 9];
	PRVM_serveredictfloat(ed, dphitcontentsmask) = (tv_rnd() % 6) == 0 ? masks[tv_rnd() % 4] : 0;
	PRVM_serveredictedict(ed, owner) = (tv_rnd() % 8) == 0 ? 1 + (int)(tv_rnd() % 24) : 0;
	smv_randsize(n, kind != 2);
}

// a resting origin for n's box on something below a random point (world, a bmodel or a box entity)
static int smv_floor(int n, float *org, float minnz)
{
	prvm_prog_t *prog = SVVM_prog;
	prvm_edict_t *ed = SMV_ED(n);
	float s[3], e[3];
	trace_t t;
	int i;
	for (i = 0; i < 80; i++)
	{
		s[0] = tv_frand(-540, 540);
		s[1] = tv_frand(-540, 540);
		s[2] = tv_frand(-250, 650);
		VectorCopy(s, e);
		e[2] -= 900;
		t = SV_TraceBox(s, PRVM_serveredictvector(ed, mins), PRVM_serveredictvector(ed, maxs), e, MOVE_NORMAL, ed, SV_GenericHitSuperContentsMask(ed), 0, 0, 0);
		if (!t.startsolid && t.fraction < 1 && t.plane.normal[2] > minnz)
		{
			VectorCopy(t.endpos, org);
			return 1;
		}
	}
	return 0;
}
// an origin in the open (box not stuck, no contents)
static int smv_open(int n, float *org)
{
	prvm_prog_t *prog = SVVM_prog;
	prvm_edict_t *ed = SMV_ED(n);
	trace_t t;
	int i, j;
	for (i = 0; i < 80; i++)
	{
		for (j = 0; j < 3; j++)
			org[j] = tv_frand(-520, 520);
		t = SV_TraceBox(org, PRVM_serveredictvector(ed, mins), PRVM_serveredictvector(ed, maxs), org, MOVE_NORMAL, ed, SV_GenericHitSuperContentsMask(ed), 0, 0, 0);
		if (!t.startsolid && !SV_PointSuperContents(org))
			return 1;
	}
	return 0;
}
// an origin in a world water brush
static int smv_water(int n, float *org)
{
	prvm_prog_t *prog = SVVM_prog;
	prvm_edict_t *ed = SMV_ED(n);
	trace_t t;
	int i, j, b;
	for (i = 0; i < 200; i++)
	{
		b = (int)(tv_rnd() % TV_NWORLDB);
		if (!tv_brush[b].colbrushf || tv_brush[b].texture->supercontents != SUPERCONTENTS_WATER)
			continue;
		for (j = 0; j < 3; j++)
			org[j] = tv_bcenter[b][j] + tv_frand(-12, 12);
		t = SV_TraceBox(org, PRVM_serveredictvector(ed, mins), PRVM_serveredictvector(ed, maxs), org, MOVE_NORMAL, ed, SV_GenericHitSuperContentsMask(ed), 0, 0, 0);
		if (!t.startsolid && (SV_PointSuperContents(org) & SUPERCONTENTS_LIQUIDSMASK))
			return 1;
	}
	return 0;
}
static void smv_setorg(int n, const float *org)
{
	prvm_prog_t *prog = SVVM_prog;
	VectorCopy(org, PRVM_serveredictvector(SMV_ED(n), origin));
}
static int smv_pickany(void) // any edict but the never linked ones, sometimes the world or a free one
{
	int r = (int)(tv_rnd() % 20);
	if (r == 0)
		return 0;
	if (r == 1)
		return SMV_FREE0 + (int)(tv_rnd() % 3);
	if (r < 9)
		return 1 + (int)(tv_rnd() % 24);
	return SMV_A0 + (int)(tv_rnd() % SMV_NA);
}

// obstacles 1 .. 24: bmodels of the submodel, boxes, monsters, triggers with touch functions, items, corpses
static void smv_obstacle(int n)
{
	static const float x800[3] = {800, 0, 0};
	prvm_prog_t *prog = SVVM_prog;
	prvm_edict_t *ed = SMV_ED(n);
	float target[3], off[3], *a, mins[3], maxs[3];
	matrix4x4_t m;
	int j, r = (int)(tv_rnd() % 100);
	smv_clear(n);
	for (j = 0; j < 3; j++)
		target[j] = tv_frand(-450, 450);
	target[2] = tv_frand(-300, 300);
	a = PRVM_serveredictvector(ed, angles);
	if (r < 30)
	{
		PRVM_serveredictfloat(ed, solid) = SOLID_BSP;
		PRVM_serveredictfloat(ed, movetype) = MOVETYPE_PUSH;
		PRVM_serveredictfloat(ed, modelindex) = 2;
		if (tv_rnd() % 3 == 0)
			a[1] = tv_frand(-180, 180);
		Matrix4x4_CreateFromQuakeEntity(&m, 0, 0, 0, a[0], a[1], a[2], 1);
		Matrix4x4_Transform(&m, x800, off);
		VectorSubtract(target, off, PRVM_serveredictvector(ed, origin));
		smv_setsize(n, tv_model[1].normalmins, tv_model[1].normalmaxs);
		return;
	}
	VectorCopy(target, PRVM_serveredictvector(ed, origin));
	for (j = 0; j < 3; j++)
	{
		mins[j] = -tv_frand(4, 40);
		maxs[j] = tv_frand(4, 40);
	}
	smv_setsize(n, mins, maxs);
	if (r < 55)
		PRVM_serveredictfloat(ed, solid) = SOLID_BBOX;
	else if (r < 65)
	{
		PRVM_serveredictfloat(ed, solid) = SOLID_SLIDEBOX;
		PRVM_serveredictfloat(ed, flags) = FL_MONSTER | FL_ONGROUND;
	}
	else if (r < 85)
	{
		PRVM_serveredictfloat(ed, solid) = SOLID_TRIGGER;
		PRVM_serveredictfunction(ed, touch) = 1 + (int)(tv_rnd() % 50);
	}
	else if (r < 93)
	{
		PRVM_serveredictfloat(ed, solid) = SOLID_NOT;
		PRVM_serveredictfloat(ed, flags) = FL_ITEM;
	}
	else
		PRVM_serveredictfloat(ed, solid) = SOLID_CORPSE;
}

// ---- cos / sin of the radian yaws walkmove and SV_StepDirection compute (glibc libm on the runner)
static void smv_cossin(float deg)
{
	float yaw = deg;
	yaw = yaw * M_PI * 2 / 360;
	printf("CS\t%08x\t%016llx\t%016llx\n", tv_bits(yaw), tv_dbits(cos(yaw)), tv_dbits(sin(yaw)));
}

// ---- SV_CheckBottom
static void smv_case_checkbottom(int builtin)
{
	prvm_prog_t *prog = SVVM_prog;
	int n = smv_nextactor(), r, argc = 1;
	float org[3];
	smv_actor(n, 0);
	if (!smv_floor(n, org, (tv_rnd() % 3) ? 0.05f : 0.6f))
		return;
	r = (int)(tv_rnd() % 12);
	if (r < 3)
	{
		org[0] += tv_frand(-40, 40);
		org[1] += tv_frand(-40, 40);
	}
	else if (r < 5)
		org[2] += tv_frand(0, 80);
	else if (r == 5)
		org[2] += (tv_rnd() % 2) ? 0.03125f : -0.03125f;
	else if (r == 6)
		org[2] -= tv_frand(0, 12);
	smv_setorg(n, org);
	if (tv_rnd() % 4)
		smv_link(n);
	if (builtin)
	{
		PRVM_G_INT(OFS_PARM0) = n;
		argc = (tv_rnd() % 15) == 0 ? 2 : 1;
		smv_begin();
		printf("B\tcheckbottom\t%d\n", argc);
		prog->argc = argc;
		SMV_CALL(smv_vm_checkbottom(prog));
		smv_end();
		smv_count(argc != 1 ? "checkbottom_builtin_error" : PRVM_G_FLOAT(OFS_RETURN) ? "checkbottom_builtin_1" : "checkbottom_builtin_0");
		return;
	}
	smv_begin();
	printf("CB\t%d\n", n);
	SMV_CALL(r = SV_CheckBottom(SMV_ED(n)); printf("RV\t%d\n", r));
	smv_end();
	smv_count(c_no == smv_cn0 ? "checkbottom_easy_yes" : r ? "checkbottom_real_yes" : "checkbottom_real_no");
}

// ---- SV_movestep
// what SV_movestep will do with a walker (the same traces, no side effects; for the branch counts)
static const char *smv_walkclass(int n, const float *move, int *steep)
{
	prvm_prog_t *prog = SVVM_prog;
	prvm_edict_t *ed = SMV_ED(n);
	float neworg[3], end[3], save[3];
	int partial = ((int)PRVM_serveredictfloat(ed, flags) & FL_PARTIALGROUND) != 0, ok, cy = c_yes, cn = c_no;
	trace_t t;
	*steep = 0;
	VectorAdd(PRVM_serveredictvector(ed, origin), move, neworg);
	neworg[2] += sv_stepheight.value;
	VectorCopy(neworg, end);
	end[2] -= sv_stepheight.value * 2;
	t = SV_TraceBox(neworg, PRVM_serveredictvector(ed, mins), PRVM_serveredictvector(ed, maxs), end, MOVE_NORMAL, ed, SV_GenericHitSuperContentsMask(ed), 0, 0, collision_extendmovelength.value);
	if (t.startsolid)
	{
		neworg[2] -= sv_stepheight.value;
		t = SV_TraceBox(neworg, PRVM_serveredictvector(ed, mins), PRVM_serveredictvector(ed, maxs), end, MOVE_NORMAL, ed, SV_GenericHitSuperContentsMask(ed), 0, 0, collision_extendmovelength.value);
		if (t.startsolid)
			return "walk_blocked_startsolid";
	}
	if (t.fraction == 1)
		return partial ? "walk_partialground_fall" : "walk_edge";
	*steep = t.plane.normal[2] < 0.5;
	VectorCopy(PRVM_serveredictvector(ed, origin), save);
	VectorCopy(t.endpos, PRVM_serveredictvector(ed, origin));
	ok = SV_CheckBottom(ed);
	VectorCopy(save, PRVM_serveredictvector(ed, origin));
	c_yes = cy;
	c_no = cn;
	if (!ok)
		return partial ? "walk_checkbottom_fail_partialground" : "walk_checkbottom_fail";
	if (*steep && sv_gameplayfix_nostepmoveonsteepslopes.integer)
		return "walk_steep_refused";
	if (t.endpos[2] > save[2] + 0.01)
		return "walk_ok_step_up";
	if (t.endpos[2] < save[2] - 0.01)
		return "walk_ok_step_down";
	return "walk_ok_flat";
}
static void smv_movestep(int n, const float *move, int relink, int noenemy, int settrace)
{
	int r = 0;
	smv_begin();
	printf("MS\t%d", n);
	tv_pv(move);
	printf("\t%d\t%d\t%d\n", relink, noenemy, settrace);
	SMV_CALL(r = SV_movestep(SMV_ED(n), (float *)move, relink, noenemy, settrace); printf("RV\t%d\n", r));
	smv_end();
	(void)r;
}
static void smv_randmove(float *move, int vertical)
{
	static const float dists[8] = {2, 8, 16, 24, 31, 40, 64, 0.5f};
	float a = tv_frand(0, 360), d = dists[tv_rnd() % 8];
	move[0] = cos(a * M_PI / 180) * d;
	move[1] = sin(a * M_PI / 180) * d;
	move[2] = vertical ? tv_frand(-12, 12) : 0;
}
static void smv_case_walk(void)
{
	prvm_prog_t *prog = SVVM_prog;
	int n = smv_nextactor(), steep;
	float org[3], move[3];
	const char *cls;
	smv_actor(n, 0);
	if (!smv_floor(n, org, (tv_rnd() % 3) ? 0.05f : 0.6f))
		return;
	if (tv_rnd() % 10 == 0)
		org[2] += tv_frand(1, 40);
	smv_setorg(n, org);
	if (tv_rnd() % 8)
		smv_link(n);
	smv_randmove(move, (tv_rnd() % 8) == 0);
	cls = smv_walkclass(n, move, &steep);
	smv_movestep(n, move, (tv_rnd() % 4) != 0, (int)(tv_rnd() % 2), (tv_rnd() % 3) == 0);
	smv_count(cls);
	if (steep)
		smv_count(sv_gameplayfix_nostepmoveonsteepslopes.integer ? "walk_steep_plane_fix1" : "walk_steep_plane_fix0");
	(void)prog;
}
static float smv_enemyband(int n, int *noenemy)
{
	static const float dzs[12] = {-60, -20, 0, 10, 25, 29.5f, 30, 35, 40, 40.5f, 50, 100};
	prvm_prog_t *prog = SVVM_prog;
	float o[3], dz = 0;
	int r = (int)(tv_rnd() % 10);
	*noenemy = r == 0;
	if (r == 1)
		PRVM_serveredictedict(SMV_ED(n), enemy) = 0;
	else
	{
		dz = dzs[tv_rnd() % 12];
		VectorCopy(PRVM_serveredictvector(SMV_ED(n), origin), o);
		o[0] += tv_frand(-200, 200);
		o[1] += tv_frand(-200, 200);
		o[2] -= dz;
		smv_setorg(SMV_ENEMY, o);
		PRVM_serveredictedict(SMV_ED(n), enemy) = SMV_ENEMY;
	}
	return dz;
}
static void smv_case_fly(int swim)
{
	prvm_prog_t *prog = SVVM_prog;
	int n = smv_nextactor(), noenemy, enemy, inwater = 0, r = 0;
	float org[3], move[3], dz;
	smv_actor(n, swim ? 2 : 1);
	if (swim && (tv_rnd() % 5))
		inwater = smv_water(n, org);
	if (!inwater && !smv_open(n, org))
		return;
	smv_setorg(n, org);
	if (tv_rnd() % 8)
		smv_link(n);
	dz = smv_enemyband(n, &noenemy);
	enemy = PRVM_serveredictedict(SMV_ED(n), enemy);
	smv_randmove(move, (tv_rnd() % 3) == 0);
	smv_begin();
	printf("MS\t%d", n);
	tv_pv(move);
	r = (int)(tv_rnd() % 4) != 0;
	printf("\t%d\t%d\t%d\n", r, noenemy, 0);
	SMV_CALL(r = SV_movestep(SMV_ED(n), move, r, noenemy, false); printf("RV\t%d\n", r));
	smv_end();
	if (swim)
		smv_count(inwater ? (r ? "swim_inwater_ok" : "swim_inwater_fail") : (r ? "swim_outofwater_ok" : "swim_outofwater_fail"));
	else
		smv_count(r ? "fly_ok" : "fly_fail");
	smv_count(noenemy ? "flyswim_noenemy" : !enemy ? "flyswim_enemy_world" : dz > 40 ? "flyswim_dz_above40" : dz < 30 ? "flyswim_dz_below30" : "flyswim_dz_30to40");
}

// ---- SV_StepDirection
static void smv_case_stepdir(int k)
{
	static const float dists[6] = {0, 4, 8, 16, 20.5f, 32};
	prvm_prog_t *prog = SVVM_prog;
	int n = smv_nextactor(), fly = (tv_rnd() % 4) == 0, s, r = 0, noenemy;
	float org[3], yaw, dist, old[3];
	smv_actor(n, fly);
	if (fly ? !smv_open(n, org) : !smv_floor(n, org, 0.05f))
		return;
	smv_setorg(n, org);
	smv_link(n);
	if (fly)
		smv_enemyband(n, &noenemy);
	yaw = (k % 48) * 7.5f;
	if ((k / 48) % 3 == 1)
		yaw += tv_frand(-3, 3);
	if ((k / 48) % 5 == 4)
		yaw += (tv_rnd() % 2) ? 360 : -360;
	dist = dists[tv_rnd() % 6];
	s = (int)(tv_rnd() % 12);
	s = s < 9 ? n : s == 9 ? smv_pickany() : s == 10 ? 0 : SMV_FREE0;
	PRVM_serverglobaledict(self) = s;
	VectorCopy(org, old);
	smv_begin();
	printf("SD\t%d", n);
	tv_pf(yaw);
	tv_pf(dist);
	printf("\n");
	SMV_CALL(r = smv_StepDirection(SMV_ED(n), yaw, dist); printf("RV\t%d\n", r));
	smv_end();
	smv_count(!r ? "stepdir_blocked" : VectorCompare(old, PRVM_serveredictvector(SMV_ED(n), origin)) ? "stepdir_ok_not_turned_far_enough_or_zero" : "stepdir_ok_moved");
	smv_count(s == n ? "stepdir_self_is_ent" : s == 0 ? "stepdir_self_world" : s == SMV_FREE0 ? "stepdir_self_free" : "stepdir_self_other");
}

// ---- SV_NewChaseDir / SV_CloseEnough / VM_SV_MoveToGoal
static void smv_placegoal(int n, int dir, float d)
{
	static const int dx[9] = {1, 1, 0, -1, -1, -1, 0, 1, 0}, dy[9] = {0, 1, 1, 1, 0, -1, -1, -1, 0};
	prvm_prog_t *prog = SVVM_prog;
	float o[3], mins[3] = {-8, -8, -8}, maxs[3] = {8, 8, 8};
	VectorCopy(PRVM_serveredictvector(SMV_ED(n), origin), o);
	o[0] += dx[dir] * d + tv_frand(-4, 4);
	o[1] += dy[dir] * d + tv_frand(-4, 4);
	o[2] += tv_frand(-30, 30);
	smv_clear(SMV_GOAL);
	PRVM_serveredictfloat(SMV_ED(SMV_GOAL), solid) = SOLID_TRIGGER;
	smv_setsize(SMV_GOAL, mins, maxs);
	smv_setorg(SMV_GOAL, o);
	smv_link(SMV_GOAL);
}
static int smv_chaser(int *n)
{
	prvm_prog_t *prog = SVVM_prog;
	int fly = (tv_rnd() % 5) == 0, noenemy;
	float org[3];
	*n = smv_nextactor();
	smv_actor(*n, fly);
	if (fly ? !smv_open(*n, org) : !smv_floor(*n, org, 0.05f))
		return 0;
	if (tv_rnd() % 4 == 0)
		PRVM_serveredictfloat(SMV_ED(*n), ideal_yaw) = (float)(45 * (int)(tv_rnd() % 8));
	smv_setorg(*n, org);
	smv_link(*n);
	if (fly)
		smv_enemyband(*n, &noenemy);
	return 1;
}
static void smv_case_chase(int k)
{
	static const float dists[6] = {5, 9, 11, 30, 120, 400}, steps[6] = {8, 16, 24, 48, 200, 3};
	prvm_prog_t *prog = SVVM_prog;
	int n, flags;
	float old[3], dist;
	if (!smv_chaser(&n))
		return;
	smv_placegoal(n, k % 9, dists[(k / 9) % 6]);
	dist = steps[tv_rnd() % 6];
	PRVM_serverglobaledict(self) = n;
	VectorCopy(PRVM_serveredictvector(SMV_ED(n), origin), old);
	flags = (int)PRVM_serveredictfloat(SMV_ED(n), flags);
	smv_begin();
	smv_seed();
	printf("NC\t%d\t%d", n, SMV_GOAL);
	tv_pf(dist);
	printf("\n");
	SMV_CALL(smv_NewChaseDir(SMV_ED(n), SMV_ED(SMV_GOAL), dist));
	smv_end();
	if (!VectorCompare(old, PRVM_serveredictvector(SMV_ED(n), origin)))
		smv_count("chase_moved");
	else if (!(flags & FL_PARTIALGROUND) && ((int)PRVM_serveredictfloat(SMV_ED(n), flags) & FL_PARTIALGROUND))
		smv_count("chase_stuck_fixcheckbottom");
	else
		smv_count("chase_not_moved");
}
static void smv_case_closeenough(void)
{
	static const float dists[6] = {-10, 0, 1, 16, 64, 300};
	int a = SMV_A0 + (int)(tv_rnd() % SMV_NA), g = (tv_rnd() % 3) ? SMV_GOAL : 1 + (int)(tv_rnd() % 24), r = 0;
	float d = dists[tv_rnd() % 6];
	smv_begin();
	printf("CE\t%d\t%d", a, g);
	tv_pf(d);
	printf("\n");
	SMV_CALL(r = smv_CloseEnough(SMV_ED(a), SMV_ED(g), d); printf("RV\t%d\n", r));
	smv_end();
	smv_count(r ? "closeenough_1" : "closeenough_0");
}
static void smv_case_movetogoal(int k)
{
	static const float dists[6] = {5, 9, 11, 30, 120, 400}, steps[6] = {8, 16, 24, 48, 200, 3};
	prvm_prog_t *prog = SVVM_prog;
	int n, argc, close, r = (int)(tv_rnd() % 10);
	float old[3], dist;
	if (!smv_chaser(&n))
		return;
	smv_placegoal(n, k % 9, dists[(k / 9) % 6]);
	dist = steps[tv_rnd() % 6];
	PRVM_serveredictedict(SMV_ED(n), goalentity) = SMV_GOAL;
	PRVM_serveredictedict(SMV_ED(n), enemy) = r < 5 ? SMV_GOAL : r < 8 ? 0 : SMV_ENEMY;
	if (tv_rnd() % 7 == 0)
		PRVM_serveredictfloat(SMV_ED(n), flags) = (int)PRVM_serveredictfloat(SMV_ED(n), flags) & ~(FL_ONGROUND | FL_FLY | FL_SWIM);
	PRVM_serverglobaledict(self) = n;
	PRVM_G_FLOAT(OFS_PARM0) = dist;
	argc = (tv_rnd() % 25) == 0 ? 2 : 1;
	VectorCopy(PRVM_serveredictvector(SMV_ED(n), origin), old);
	close = smv_CloseEnough(SMV_ED(n), SMV_ED(SMV_GOAL), dist);
	smv_begin();
	smv_seed();
	printf("B\tmovetogoal\t%d\n", argc);
	prog->argc = argc;
	SMV_CALL(VM_SV_MoveToGoal(prog));
	smv_end();
	if (argc != 1)
		smv_count("movetogoal_error");
	else if (!((int)PRVM_serveredictfloat(SMV_ED(n), flags) & (FL_ONGROUND | FL_FLY | FL_SWIM)))
		smv_count("movetogoal_not_on_ground");
	else if (PRVM_serveredictedict(SMV_ED(n), enemy) && close)
		smv_count("movetogoal_close_enough");
	else
		smv_count(VectorCompare(old, PRVM_serveredictvector(SMV_ED(n), origin)) ? "movetogoal_not_moved" : "movetogoal_moved");
}

// ---- walkmove
static void smv_case_walkmove(int k)
{
	static const float dists[7] = {0, 4, 8, 16, 20, 32, 64};
	prvm_prog_t *prog = SVVM_prog;
	int n = smv_nextactor(), fly = (tv_rnd() % 4) == 0, argc, s, noenemy, r = (int)(tv_rnd() % 30);
	float org[3], old[3], yaw;
	smv_actor(n, fly);
	if (fly ? !smv_open(n, org) : !smv_floor(n, org, 0.05f))
		return;
	smv_setorg(n, org);
	smv_link(n);
	if (fly)
		smv_enemyband(n, &noenemy);
	if (tv_rnd() % 8 == 0)
		PRVM_serveredictfloat(SMV_ED(n), flags) = (int)PRVM_serveredictfloat(SMV_ED(n), flags) & ~(FL_ONGROUND | FL_FLY | FL_SWIM);
	yaw = (k % 72) * 5.0f;
	if ((k / 72) % 2)
		yaw += tv_frand(-2.5f, 2.5f);
	if ((k / 72) % 7 == 3)
		yaw = tv_frand(-1000, 1000);
	PRVM_G_FLOAT(OFS_PARM0) = yaw;
	PRVM_G_FLOAT(OFS_PARM1) = dists[tv_rnd() % 7];
	PRVM_G_FLOAT(OFS_PARM2) = (float)(tv_rnd() % 2);
	argc = r == 0 ? 1 : r == 1 ? 4 : (tv_rnd() % 2) ? 3 : 2;
	s = (int)(tv_rnd() % 20);
	s = s == 0 ? 0 : s == 1 ? SMV_FREE0 + 1 : n;
	PRVM_serverglobaledict(self) = s;
	VectorCopy(org, old);
	smv_begin();
	printf("B\twalkmove\t%d\n", argc);
	prog->argc = argc;
	SMV_CALL(smv_vm_walkmove(prog));
	smv_end();
	if (argc < 2 || argc > 3)
		smv_count("walkmove_error");
	else if (s != n)
		smv_count("walkmove_world_or_free");
	else if (!((int)PRVM_serveredictfloat(SMV_ED(n), flags) & (FL_ONGROUND | FL_FLY | FL_SWIM)))
		smv_count("walkmove_not_on_ground");
	else
		smv_count(PRVM_G_FLOAT(OFS_RETURN) ? (VectorCompare(old, PRVM_serveredictvector(SMV_ED(n), origin)) ? "walkmove_1_not_moved" : "walkmove_1_moved") : "walkmove_0");
}

// ---- droptofloor
static void smv_case_droptofloor(void)
{
	prvm_prog_t *prog = SVVM_prog;
	int n = smv_nextactor(), r = (int)(tv_rnd() % 20), argc, s, b, j, startsolid;
	float org[3], mins[3] = {-16, -16, 0}, maxs[3] = {16, 16, 48};
	trace_t t;
	smv_actor(n, 0);
	if (tv_rnd() % 3 == 0) // an item
	{
		PRVM_serveredictfloat(SMV_ED(n), solid) = SOLID_TRIGGER;
		PRVM_serveredictfloat(SMV_ED(n), flags) = FL_ITEM;
		PRVM_serveredictfloat(SMV_ED(n), movetype) = MOVETYPE_TOSS;
		if (tv_rnd() % 2)
			smv_setsize(n, mins, maxs);
	}
	if (r < 8) // above a floor (free fall, or more than 256 above: nothing below)
	{
		if (!smv_floor(n, org, 0.05f))
			return;
		org[2] += (tv_rnd() % 4) ? tv_frand(0, 200) : tv_frand(200, 400);
	}
	else if (r < 12) // in a world brush
	{
		b = tv_pickbrush(0);
		for (j = 0; j < 3; j++)
			org[j] = tv_bcenter[b][j] + tv_frand(-10, 10);
	}
	else if (r < 16) // partly in the floor
	{
		if (!smv_floor(n, org, 0.05f))
			return;
		org[2] -= tv_frand(0.5f, 20);
		org[0] += tv_frand(-4, 4);
	}
	else if (r < 18) // nothing below
	{
		org[0] = tv_frand(-500, 500);
		org[1] = tv_frand(-500, 500);
		org[2] = (tv_rnd() % 2) ? -900 : 950;
	}
	else
	{
		for (j = 0; j < 3; j++)
			org[j] = tv_frand(-520, 520);
	}
	smv_setorg(n, org);
	if (tv_rnd() % 5)
		smv_link(n);
	r = (int)(tv_rnd() % 30);
	argc = r == 0 ? 3 : r < 3 ? 1 : r < 4 ? 2 : 0;
	s = (int)(tv_rnd() % 25);
	s = s == 0 ? 0 : s == 1 ? SMV_FREE0 + 2 : n;
	PRVM_serverglobaledict(self) = s;
	t = SV_TraceBox(org, PRVM_serveredictvector(SMV_ED(n), mins), PRVM_serveredictvector(SMV_ED(n), maxs), org, MOVE_NORMAL, SMV_ED(n), SV_GenericHitSuperContentsMask(SMV_ED(n)), 0, 0, 0);
	startsolid = t.startsolid;
	smv_begin();
	printf("B\tdroptofloor\t%d\n", argc);
	prog->argc = argc;
	SMV_CALL(smv_vm_droptofloor(prog));
	smv_end();
	if (argc > 2)
		smv_count("droptofloor_error");
	else if (s != n)
		smv_count("droptofloor_world_or_free");
	else if (startsolid)
		smv_count(PRVM_G_FLOAT(OFS_RETURN) ? "droptofloor_startsolid_1" : "droptofloor_startsolid_0");
	else
		smv_count(PRVM_G_FLOAT(OFS_RETURN) ? "droptofloor_1" : "droptofloor_0");
}

// ---- traceline / tracebox / tracetoss
static void smv_aimpoints(float *start, float *end)
{
	prvm_prog_t *prog = SVVM_prog;
	float dir[3], a;
	int j, n;
	if (tv_rnd() % 5 < 2)
	{
		n = 1 + (int)(tv_rnd() % 54);
		tv_randnormal(dir);
		a = tv_frand(20, 400);
		for (j = 0; j < 3; j++)
		{
			end[j] = PRVM_serveredictvector(SMV_ED(n), origin)[j] + tv_frand(-20, 20);
			start[j] = end[j] + dir[j] * a;
		}
		if (tv_rnd() % 2)
			for (j = 0; j < 3; j++)
				end[j] -= dir[j] * tv_frand(0, 100);
	}
	else
		tv_aim(0, start, end, 0);
}
static void smv_nan(float *v1, float *v2)
{
	static const uint32_t nans[2] = {0x7fc00000u, 0xffc00000u};
	float *v = (tv_rnd() % 2) ? v1 : v2;
	memcpy(v + tv_rnd() % 3, nans + tv_rnd() % 2, 4);
}
static const char *smv_traceclass(const char *ok, const char *hitworld, const char *hitent, const char *startsolid)
{
	prvm_prog_t *prog = SVVM_prog;
	if (PRVM_serverglobalfloat(trace_startsolid))
		return startsolid;
	if (PRVM_serverglobalfloat(trace_fraction) == 1)
		return ok;
	return PRVM_serverglobaledict(trace_ent) ? hitent : hitworld;
}
static void smv_case_trace(int box)
{
	static const int moves[7] = {MOVE_NORMAL, MOVE_NORMAL, MOVE_NOMONSTERS, MOVE_MISSILE, MOVE_WORLDONLY, MOVE_HITMODEL, 5};
	prvm_prog_t *prog = SVVM_prog;
	float v1[3], v2[3], m1[3], m2[3];
	int j, r = (int)(tv_rnd() % 40), argc, nanin = 0;
	smv_aimpoints(v1, v2);
	if (r == 0)
	{
		smv_nan(v1, v2);
		nanin = 1;
	}
	r = (int)(tv_rnd() % 30);
	if (box)
	{
		r = (int)(tv_rnd() % 8);
		if (r == 0)
		{
			VectorClear(m1);
			VectorClear(m2);
		}
		else if (r < 4)
		{
			VectorSet(m1, -16, -16, -24);
			VectorSet(m2, 16, 16, 45);
		}
		else
		{
			for (j = 0; j < 3; j++)
			{
				m1[j] = -tv_frand(0, 30);
				m2[j] = tv_frand(0, 30);
			}
		}
		VectorCopy(v1, PRVM_G_VECTOR(OFS_PARM0));
		VectorCopy(m1, PRVM_G_VECTOR(OFS_PARM1));
		VectorCopy(m2, PRVM_G_VECTOR(OFS_PARM2));
		VectorCopy(v2, PRVM_G_VECTOR(OFS_PARM3));
		PRVM_G_FLOAT(OFS_PARM4) = moves[tv_rnd() % 7];
		PRVM_G_INT(OFS_PARM5) = smv_pickany();
		r = (int)(tv_rnd() % 40);
		argc = r == 0 ? 5 : r == 1 ? 9 : 6 + (int)(tv_rnd() % 3);
	}
	else
	{
		VectorCopy(v1, PRVM_G_VECTOR(OFS_PARM0));
		VectorCopy(v2, PRVM_G_VECTOR(OFS_PARM1));
		PRVM_G_FLOAT(OFS_PARM2) = moves[tv_rnd() % 7];
		PRVM_G_INT(OFS_PARM3) = smv_pickany();
		r = (int)(tv_rnd() % 40);
		argc = r == 0 ? 3 : r == 1 ? 9 : (tv_rnd() % 4) ? 4 : 5 + (int)(tv_rnd() % 4);
	}
	smv_begin();
	printf("B\t%s\t%d\n", box ? "tracebox" : "traceline", argc);
	prog->argc = argc;
	SMV_CALL(if (box) smv_vm_tracebox(prog); else smv_vm_traceline(prog));
	smv_end();
	if (argc < (box ? 6 : 4) || argc > 8)
		smv_count(box ? "tracebox_parmcount_error" : "traceline_parmcount_error");
	else if (nanin)
		smv_count(box ? "tracebox_nan_error" : "traceline_nan_error");
	else if (box)
		smv_count(smv_traceclass("tracebox_nohit", "tracebox_hit_world", "tracebox_hit_entity", "tracebox_startsolid"));
	else
		smv_count(smv_traceclass("traceline_nohit", "traceline_hit_world", "traceline_hit_entity", "traceline_startsolid"));
}
static void smv_case_tracetoss(void)
{
	static const float gravs[6] = {0, 0, 1, 0.5f, 2, -0.1f};
	prvm_prog_t *prog = SVVM_prog;
	int n = smv_nextactor(), j, argc, e, r = (int)(tv_rnd() % 30);
	float org[3], *v;
	smv_actor(n, 1);
	PRVM_serveredictfloat(SMV_ED(n), movetype) = MOVETYPE_TOSS;
	if (!smv_open(n, org))
		return;
	smv_setorg(n, org);
	if (tv_rnd() % 3)
		smv_link(n);
	v = PRVM_serveredictvector(SMV_ED(n), velocity);
	for (j = 0; j < 3; j++)
		v[j] = tv_frand(-900, 900);
	if (tv_rnd() % 4 == 0)
		v[2] = tv_frand(1000, 3000);
	if (tv_rnd() % 10 == 0)
		VectorClear(v);
	PRVM_serveredictfloat(SMV_ED(n), gravity) = gravs[tv_rnd() % 6];
	if (tv_rnd() % 2)
		VectorSet(PRVM_serveredictvector(SMV_ED(n), avelocity), tv_frand(-300, 300), tv_frand(-300, 300), tv_frand(-300, 300));
	e = r == 0 ? 0 : n;
	PRVM_G_INT(OFS_PARM0) = e;
	PRVM_G_INT(OFS_PARM1) = smv_pickany();
	argc = r == 1 ? 1 : 2;
	smv_begin();
	printf("B\ttracetoss\t%d\n", argc);
	prog->argc = argc;
	SMV_CALL(smv_vm_tracetoss(prog));
	smv_end();
	if (argc != 2)
		smv_count("tracetoss_error");
	else if (!e)
		smv_count("tracetoss_world");
	else
		smv_count(smv_traceclass("tracetoss_nohit", "tracetoss_hit_world", "tracetoss_hit_entity", "tracetoss_startsolid"));
}

// ---- setorigin / setsize
static void smv_case_setorigin(void)
{
	prvm_prog_t *prog = SVVM_prog;
	int e = smv_pickany(), j, argc = (tv_rnd() % 20) == 0 ? 3 : 2;
	for (j = 0; j < 3; j++)
		PRVM_G_VECTOR(OFS_PARM1)[j] = tv_frand(-500, 500);
	PRVM_G_INT(OFS_PARM0) = e;
	if (tv_rnd() % 4 == 0)
		smv_priv[e].mark = (tv_rnd() % 2) ? -1 : 3;
	smv_begin();
	printf("B\tsetorigin\t%d\n", argc);
	prog->argc = argc;
	SMV_CALL(smv_vm_setorigin(prog));
	smv_end();
	smv_count(argc != 2 ? "setorigin_error" : e == 0 ? "setorigin_world" : smv_priv[e].free ? "setorigin_free" : smv_priv[e].mark == -2 ? "setorigin_mark_caught" : "setorigin_ok");
}
static void smv_case_setsize(void)
{
	prvm_prog_t *prog = SVVM_prog;
	int e = smv_pickany(), j, r = (int)(tv_rnd() % 10), argc = (tv_rnd() % 20) == 0 ? 2 : 3;
	float *mins = PRVM_G_VECTOR(OFS_PARM1), *maxs = PRVM_G_VECTOR(OFS_PARM2);
	for (j = 0; j < 3; j++)
	{
		mins[j] = -tv_frand(0, 40);
		maxs[j] = tv_frand(0, 50);
	}
	if (r == 0)
		mins[tv_rnd() % 3] = 60; // backwards
	else if (r == 1)
		VectorCopy(mins, maxs);
	PRVM_G_INT(OFS_PARM0) = e;
	smv_begin();
	printf("B\tsetsize\t%d\n", argc);
	prog->argc = argc;
	SMV_CALL(smv_vm_setsize(prog));
	smv_end();
	smv_count(argc != 3 ? "setsize_parmcount_error" : e == 0 ? "setsize_world" : smv_priv[e].free ? "setsize_free" : r == 0 ? "setsize_backwards_error" : "setsize_ok");
}

// ---- findradius
static void smv_case_findradius(void)
{
	static const float radii[9] = {0, 1, 10, 50, 100, 300, 1000, -5, 24.5f};
	prvm_prog_t *prog = SVVM_prog;
	int j, n, argc, r = (int)(tv_rnd() % 10);
	float *org = PRVM_G_VECTOR(OFS_PARM0);
	n = 1 + (int)(tv_rnd() % 56);
	for (j = 0; j < 3; j++)
		org[j] = (tv_rnd() % 3) ? PRVM_serveredictvector(SMV_ED(n), origin)[j] + tv_frand(-60, 60) : tv_frand(-500, 500);
	PRVM_G_FLOAT(OFS_PARM1) = radii[tv_rnd() % 9];
	argc = 2;
	if (r < 3)
	{
		argc = 3;
		PRVM_G_INT(OFS_PARM2) = r == 0 ? -1 : r == 1 ? prog->fieldoffsets.chain : smv_chain2;
	}
	else if (r == 3)
		argc = (tv_rnd() % 2) ? 1 : 4;
	smv_begin();
	printf("B\tfindradius\t%d\n", argc);
	prog->argc = argc;
	SMV_CALL(smv_vm_findradius(prog));
	smv_end();
	smv_count(argc < 2 || argc > 3 ? "findradius_parmcount_error" : (argc == 3 && r == 0) ? "findradius_chainfield_error" : PRVM_G_INT(OFS_RETURN) ? "findradius_found" : "findradius_none");
}

// ---- pointcontents
static void smv_case_pointcontents(void)
{
	prvm_prog_t *prog = SVVM_prog;
	float *p = PRVM_G_VECTOR(OFS_PARM0), *o, *a;
	int j, b, n, argc = (tv_rnd() % 30) == 0 ? 2 : 1, r = (int)(tv_rnd() % 10);
	matrix4x4_t m;
	if (r < 4)
	{
		b = tv_pickbrush(0);
		for (j = 0; j < 3; j++)
			p[j] = tv_bcenter[b][j] + tv_frand(-8, 8);
	}
	else if (r < 7) // in a bmodel entity's brush (or a random entity's box)
	{
		n = 1 + (int)(tv_rnd() % 24);
		o = PRVM_serveredictvector(SMV_ED(n), origin);
		a = PRVM_serveredictvector(SMV_ED(n), angles);
		if ((int)PRVM_serveredictfloat(SMV_ED(n), solid) == SOLID_BSP)
		{
			b = tv_pickbrush(1);
			Matrix4x4_CreateFromQuakeEntity(&m, o[0], o[1], o[2], a[0], a[1], a[2], 1);
			Matrix4x4_Transform(&m, tv_bcenter[b], p);
		}
		else
			for (j = 0; j < 3; j++)
				p[j] = o[j] + tv_frand(-10, 10);
	}
	else
		for (j = 0; j < 3; j++)
			p[j] = tv_frand(-520, 520);
	smv_begin();
	printf("B\tpointcontents\t%d\n", argc);
	prog->argc = argc;
	SMV_CALL(smv_vm_pointcontents(prog));
	smv_end();
	if (argc != 1)
		smv_count("pointcontents_error");
	else
	{
		switch ((int)PRVM_G_FLOAT(OFS_RETURN))
		{
		case CONTENTS_EMPTY: smv_count("pointcontents_empty"); break;
		case CONTENTS_SOLID: smv_count("pointcontents_solid"); break;
		case CONTENTS_WATER: smv_count("pointcontents_water"); break;
		default: smv_count("pointcontents_other"); break;
		}
	}
}

// ---- copyentity
static void smv_case_copyentity(void)
{
	prvm_prog_t *prog = SVVM_prog;
	int in = (tv_rnd() % 6) ? SMV_A0 + (int)(tv_rnd() % SMV_NA) : smv_pickany(), out, r = (int)(tv_rnd() % 12), argc;
	out = r == 0 ? 0 : r == 1 ? SMV_FREE0 : r < 4 ? smv_pickany() : SMV_SCR0 + (int)(tv_rnd() % 4);
	if (out == SMV_ENEMY || out == SMV_GOAL)
		out = SMV_SCR0;
	if (in == SMV_ENEMY || in == SMV_GOAL)
		in = SMV_A0;
	argc = (tv_rnd() % 25) == 0 ? 1 : 2;
	PRVM_G_INT(OFS_PARM0) = in;
	PRVM_G_INT(OFS_PARM1) = out;
	smv_begin();
	printf("B\tcopyentity\t%d\n", argc);
	prog->argc = argc;
	SMV_CALL(smv_vm_copyentity(prog));
	smv_end();
	smv_count(argc != 2 ? "copyentity_error" : in == 0 || out == 0 ? "copyentity_world" : smv_priv[in].free || smv_priv[out].free ? "copyentity_free" : VectorCompare(PRVM_serveredictvector(SMV_ED(out), absmin), PRVM_serveredictvector(SMV_ED(out), absmax)) ? "copyentity_no_relink" : "copyentity_relinked");
}

// ---- the SVVM_* edict hooks
static void smv_hooks(void)
{
	prvm_prog_t *prog = SVVM_prog;
	int n;
	smv_begin();
	printf("HB\n");
	SMV_CALL(smv_begin_increase_edicts(prog));
	smv_end();
	smv_begin();
	printf("HE\n");
	SMV_CALL(smv_end_increase_edicts(prog));
	smv_end();
	smv_count("increase_edicts");
	n = SMV_SCR0 + (int)(tv_rnd() % 4);
	smv_begin();
	printf("HF\t%d\n", n);
	SMV_CALL(smv_free_edict(prog, SMV_ED(n)));
	smv_end();
	smv_count("free_edict");
}

static void smv_mixed(int count)
{
	int i, k;
	for (i = 0; i < count; i++)
	{
		k = (int)(tv_rnd() % 16);
		switch (k)
		{
		case 0: smv_case_checkbottom(0); break;
		case 1: smv_case_walk(); break;
		case 2: smv_case_fly(0); break;
		case 3: smv_case_fly(1); break;
		case 4: smv_case_stepdir(i); break;
		case 5: smv_case_chase(i); break;
		case 6: smv_case_movetogoal(i); break;
		case 7: smv_case_walkmove(i); break;
		case 8: smv_case_droptofloor(); break;
		case 9: smv_case_trace(0); break;
		case 10: smv_case_trace(1); break;
		case 11: smv_case_tracetoss(); break;
		case 12: smv_case_findradius(); break;
		case 13: smv_case_pointcontents(); break;
		case 14: smv_case_setorigin(); break;
		default: smv_case_copyentity(); break;
		}
	}
}

static void smv_run(void)
{
	prvm_prog_t *prog = SVVM_prog;
	int i, n;
	setvbuf(stdout, NULL, _IOLBF, 0); // a crash keeps every finished line (the workflow log shows the last ones)
	tv_seed = 20261129u;

	// what Collision_Init / Mod_BrushInit / SV_Init would have set by registering the cvars; the game's values
	// (physicsX.cfg, xonotic-server.cfg: sv_stepheight 31, sv_maxvelocity 1000000000,
	// sv_gameplayfix_droptofloorstartsolid 0, the rest at their registered defaults)
	collision_impactnudge.value = 0.03125f;
	collision_triangle_axialsides.integer = 1;
	mod_q3bsp_curves_collisions.integer = 1;
	mod_q3bsp_optimizedtraceline.integer = 1;
	mod_collision_bih.integer = 1;
	SMV_SETCV(collision_extendmovelength, 16);
	SMV_SETCV(collision_extendtracelinelength, 1);
	SMV_SETCV(collision_extendtraceboxlength, 1);
	SMV_SETCV(sv_areagrid_mingridsize, 128);
	SMV_SETCV(sv_debugmove, 0);
	SMV_SETCV(sv_areadebug, 0);
	SMV_SETCV(sv_gameplayfix_swiminbmodels, 1);
	SMV_SETCV(sv_legacy_bbox_expand, 1);
	SMV_SETCV(sv_gameplayfix_nudgeoutofsolid_separation, 0.03125f);
	SMV_SETCV(sv_stepheight, 31);
	SMV_SETCV(sv_gameplayfix_nostepmoveonsteepslopes, 0);
	SMV_SETCV(sv_gameplayfix_findradiusdistancetobox, 1);
	SMV_SETCV(sv_gameplayfix_blowupfallenzombies, 1);
	SMV_SETCV(sv_gameplayfix_droptofloorstartsolid, 0);
	SMV_SETCV(sv_gameplayfix_droptofloorstartsolid_nudgetocorrect, 1);
	SMV_SETCV(sv_gravity, 800);
	SMV_SETCV(sv_maxvelocity, 1000000000);

	tv_maketextures();
	for (i = 0; i < TV_NTEX; i++)
	{
		tv_tex[i].name[0] = 't';
		tv_tex[i].name[1] = 'e';
		tv_tex[i].name[2] = 'x';
		tv_tex[i].name[3] = (char)('0' + i);
		tv_tex[i].name[4] = 0;
	}
	tv_makebrushes();
	tv_makesurfaces();
	tv_makebsp();
	tv_makemodels();
	smv_setupprog();
	spv_setupserver();
	PRVM_serverglobalfloat(time) = (float)sv.time;

	for (n = 1; n <= 24; n++)
		smv_obstacle(n);
	for (n = 1; n <= 24; n++)
		smv_link(n);
	for (n = 0; n < 3; n++)
		smv_priv[SMV_FREE0 + n].free = true;

	// cos / sin of the yaws (degrees * M_PI * 2 / 360 rounded to float)
	for (i = -2880; i <= 2880; i++)
		smv_cossin(i * 0.25f);
	for (i = 0; i < 3000; i++)
		smv_cossin(tv_frand(-1000, 1000));
	for (i = 0; i < 1000; i++)
		smv_cossin(tv_frand(-1, 1) * 10);

	// the game's configuration
	for (i = 0; i < 700; i++)
		smv_case_checkbottom(i % 10 == 0);
	for (i = 0; i < 1400; i++)
		smv_case_walk();
	for (i = 0; i < 500; i++)
		smv_case_fly(0);
	for (i = 0; i < 500; i++)
		smv_case_fly(1);
	for (i = 0; i < 960; i++)
		smv_case_stepdir(i);
	for (i = 0; i < 540; i++)
		smv_case_chase(i);
	for (i = 0; i < 150; i++)
		smv_case_closeenough();
	for (i = 0; i < 540; i++)
		smv_case_movetogoal(i);
	for (i = 0; i < 720; i++)
		smv_case_walkmove(i);
	for (i = 0; i < 400; i++)
		smv_case_droptofloor();
	for (i = 0; i < 500; i++)
		smv_case_trace(0);
	for (i = 0; i < 500; i++)
		smv_case_trace(1);
	for (i = 0; i < 200; i++)
		smv_case_tracetoss();
	for (i = 0; i < 150; i++)
		smv_case_setorigin();
	for (i = 0; i < 150; i++)
		smv_case_setsize();
	for (n = 1; n <= 24; n++) // setsize may have changed them: back to the obstacle set
	{
		smv_obstacle(n);
		smv_link(n);
	}
	for (i = 0; i < 300; i++)
		smv_case_findradius();
	for (i = 0; i < 250; i++)
		smv_case_pointcontents();
	for (i = 0; i < 100; i++)
		smv_case_copyentity();
	for (i = 0; i < 4; i++)
	{
		smv_hooks();
		smv_mixed(60);
	}
	smv_mixed(800);

	// the opposite settings
	SMV_SETCV(sv_stepheight, 18);
	SMV_SETCV(sv_gameplayfix_nostepmoveonsteepslopes, 1);
	for (i = 0; i < 500; i++)
		smv_case_walk();
	for (i = 0; i < 200; i++)
		smv_case_checkbottom(0);
	for (i = 0; i < 200; i++)
		smv_case_walkmove(i);
	for (i = 0; i < 200; i++)
		smv_case_chase(i);
	for (i = 0; i < 200; i++)
		smv_case_movetogoal(i);
	SMV_SETCV(sv_stepheight, 31);
	SMV_SETCV(sv_gameplayfix_nostepmoveonsteepslopes, 0);

	SMV_SETCV(sv_gameplayfix_findradiusdistancetobox, 0);
	for (i = 0; i < 150; i++)
		smv_case_findradius();
	SMV_SETCV(sv_gameplayfix_blowupfallenzombies, 0);
	for (i = 0; i < 150; i++)
		smv_case_findradius();
	SMV_SETCV(sv_gameplayfix_findradiusdistancetobox, 1);
	for (i = 0; i < 100; i++)
		smv_case_findradius();
	SMV_SETCV(sv_gameplayfix_blowupfallenzombies, 1);

	SMV_SETCV(sv_gameplayfix_droptofloorstartsolid, 1);
	for (i = 0; i < 300; i++)
		smv_case_droptofloor();
	SMV_SETCV(sv_gameplayfix_droptofloorstartsolid_nudgetocorrect, 0);
	for (i = 0; i < 250; i++)
		smv_case_droptofloor();
	SMV_SETCV(sv_gameplayfix_droptofloorstartsolid, 0);
	for (i = 0; i < 250; i++)
		smv_case_droptofloor();
	SMV_SETCV(sv_gameplayfix_droptofloorstartsolid_nudgetocorrect, 1);

	SMV_SETCV(sv_maxvelocity, 2000);
	SMV_SETCV(sv_gravity, 750);
	for (i = 0; i < 100; i++)
		smv_case_tracetoss();
	SMV_SETCV(sv_maxvelocity, 1000000000);
	SMV_SETCV(sv_gravity, 800);

	SMV_SETCV(sv_gameplayfix_swiminbmodels, 0);
	for (i = 0; i < 100; i++)
		smv_case_pointcontents();
	for (i = 0; i < 100; i++)
		smv_case_fly(1);
	SMV_SETCV(sv_gameplayfix_swiminbmodels, 1);

	SMV_SETCV(collision_extendmovelength, 0);
	SMV_SETCV(collision_extendtracelinelength, 0);
	SMV_SETCV(collision_extendtraceboxlength, 0);
	smv_mixed(400);
	SMV_SETCV(collision_extendmovelength, 16);
	SMV_SETCV(collision_extendtracelinelength, 1);
	SMV_SETCV(collision_extendtraceboxlength, 1);

	for (i = 0; i < smv_nc; i++)
		printf("COUNT\t%s\t%d\n", smv_cname[i], smv_cval[i]);
	printf("END\n");
	(void)prog;
}

// svphys_vectors.c's main() is not this program's: the driver runs before it and exits
__attribute__((constructor)) static void smv_ctor(void)
{
	smv_run();
	fflush(stdout);
	exit(0);
}
#endif
