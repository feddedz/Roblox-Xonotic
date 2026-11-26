// Reference vectors for engine/_port/libm.luau: the libm functions DarkPlaces calls (sin, cos, tan, asin, acos,
// atan, atan2, pow, log; sqrt and fmod as a check), run on the Linux runner's glibc. Inputs are chosen to be
// hard: the angles the engine produces from float degrees, values next to multiples of pi/4, tiny, denormal and
// huge arguments (argument reduction), special values, and dense random doubles. Every input and result is
// printed as a 64-bit pattern to tests/vectors/libm.tsv:
//   V <gnu_get_libc_version()>      CPU <fma> <avx2>   (glibc picks its FMA builds at run time)
//   <fn> <x> <result>               <fn2> <y> <x> <result>   (atan2 (y, x), pow (x, y) printed as x y, fmod x y)
// Built with -fno-builtin (no compile-time folding) and called through volatile function pointers.
#define _GNU_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <float.h>
#include <math.h>
#include <gnu/libc-version.h>

static uint64_t st = 0x9E3779B97F4A7C15ull;
static uint64_t rnd64(void) // xorshift64
{
	st ^= st << 13;
	st ^= st >> 7;
	st ^= st << 17;
	return st;
}
static double unif(double lo, double hi)
{
	return lo + (hi - lo) * ((double)(rnd64() >> 11) * 0x1p-53);
}
static double logu(double lo, double hi) // log-uniform in [lo, hi], lo > 0, built without libm
{
	int elo, ehi;
	frexp(lo, &elo); // frexp is exact
	frexp(hi, &ehi);
	int e = elo + (int)(rnd64() % (uint64_t)(ehi - elo + 1));
	return ldexp(unif(0.5, 1.0), e);
}
static double sgn(double x)
{
	return (rnd64() & 1) ? -x : x;
}
static uint64_t bits(double d)
{
	uint64_t u;
	memcpy(&u, &d, 8);
	return u;
}
static double frombits(uint64_t u)
{
	double d;
	memcpy(&d, &u, 8);
	return d;
}
static double next(double x, int n) // n steps up (n > 0) or down in the bit pattern of |x|
{
	return frombits(bits(x) + (uint64_t)(int64_t)n);
}
static double randbits(void) // any finite double
{
	uint64_t u;
	do
		u = rnd64();
	while (((u >> 52) & 0x7ff) == 0x7ff);
	return frombits(u);
}

typedef double (*fn1_t)(double);
typedef double (*fn2_t)(double, double);
static volatile double vx, vy;

static void p1(const char *name, fn1_t f, double x)
{
	volatile fn1_t vf = f;
	vx = x;
	double r = vf(vx);
	printf("%s\t%016llx\t%016llx\n", name, (unsigned long long)bits(x), (unsigned long long)bits(r));
}
// atan2 (a, b) = atan2 (y, x); pow (a, b) = pow (x, y); fmod (a, b)
static void p2(const char *name, fn2_t f, double a, double b)
{
	volatile fn2_t vf = f;
	vx = a;
	vy = b;
	double r = vf(vx, vy);
	printf("%s\t%016llx\t%016llx\t%016llx\n", name, (unsigned long long)bits(a), (unsigned long long)bits(b),
		(unsigned long long)bits(r));
}

static const double specials[] = {0.0, -0.0, INFINITY, -INFINITY, NAN, -NAN, 0x1p-1074, -0x1p-1074, DBL_MIN,
	-DBL_MIN, DBL_MAX, -DBL_MAX, 1.0, -1.0, 0.5, -0.5, 2.0, -2.0};
#define NSPECIALS ((int)(sizeof(specials) / sizeof(specials[0])))

static void specials1(const char *name, fn1_t f)
{
	for (int i = 0; i < NSPECIALS; i++)
		p1(name, f, specials[i]);
}
// values around a high word threshold: the pattern itself and its neighbours, both signs
static void around(const char *name, fn1_t f, uint32_t hi)
{
	double t = frombits((uint64_t)hi << 32);
	for (int d = -2; d <= 2; d++)
	{
		p1(name, f, next(t, d));
		p1(name, f, -next(t, d));
	}
}

// sin, cos, tan: the angles the engine computes, multiples of pi/4, tiny / huge, random. div thins it out.
static void angles(const char *name, fn1_t f, int div)
{
	const double k = M_PI * 2 / 360;
	specials1(name, f);
	static const uint32_t th[] = {0x3e400000, 0x3e500000, 0x3fc00000, 0x3feb6000, 0x400368fd, 0x419921fb,
		0x3fe921fb, 0x3ff921fb, 0x400921fb, 0x4012d97c, 0x401921fb, 0x3fb00000, 0x3fd00000};
	for (int i = 0; i < (int)(sizeof(th) / sizeof(th[0])); i++)
		around(name, f, th[i]);
	// whole degrees: AngleVectors (float degrees * double constant) and sv_move (rounded to float)
	for (int d = -360; d <= 360; d += div)
	{
		float fd = (float)d;
		p1(name, f, fd * k);
		p1(name, f, (float)(fd * M_PI * 2 / 360));
	}
	// fractional float degrees, the same three ways plus float arithmetic
	for (int i = 0; i < 1600 / div; i++)
	{
		float fd = (float)unif(-1440, 1440);
		switch (i & 3)
		{
		case 0: p1(name, f, fd * k); break;
		case 1: p1(name, f, (float)(fd * M_PI * 2 / 360)); break;
		case 2: p1(name, f, (float)(fd * (float)k)); break;
		default: p1(name, f, (float)(fd * k)); break;
		}
	}
	// near multiples of pi/4 (a few ulps either side) and of pi/2 with big multipliers
	for (int q = -40; q <= 40; q += div)
		for (int d = -2; d <= 2; d++)
			p1(name, f, next(q * M_PI_4, d));
	for (int i = 0; i < 300 / div; i++)
	{
		double q = (double)(rnd64() % (1u << 26)) * ((rnd64() & 1) ? 1 : -1);
		p1(name, f, next(q * M_PI_2, (int)(rnd64() % 5) - 2));
	}
	for (int i = 0; i < 300 / div; i++) // tiny and denormal
		p1(name, f, sgn(logu(0x1p-1074, 0x1p-20)));
	for (int i = 0; i < 800 / div; i++)
		p1(name, f, unif(-10, 10));
	for (int i = 0; i < 300 / div; i++)
		p1(name, f, unif(-1000, 1000));
	for (int i = 0; i < 500 / div; i++) // huge: reduce_sincos up to 105414350, __branred beyond
		p1(name, f, sgn(logu(1e5, 1e300)));
	for (int i = 0; i < 100 / div; i++)
		p1(name, f, sgn(logu(1e7, 1e9)));
	for (int i = 0; i < 300 / div; i++)
		p1(name, f, randbits());
}

static void asincos(const char *name, fn1_t f)
{
	specials1(name, f);
	static const uint32_t th[] = {0x3c880000, 0x3e500000, 0x3fc00000, 0x3fd00000, 0x3fe00000, 0x3fe80000,
		0x3fed8000, 0x3fee8000, 0x3fef0000, 0x3ff00000};
	for (int i = 0; i < (int)(sizeof(th) / sizeof(th[0])); i++)
		around(name, f, th[i]);
	for (int i = 0; i < 800; i++)
		p1(name, f, unif(-1, 1));
	for (int i = 0; i < 500; i++)
		p1(name, f, (float)unif(-1, 1));
	for (int i = 0; i < 200; i++) // next to +-1
		p1(name, f, sgn(1.0 - logu(0x1p-53, 0x1p-5)));
	for (int i = 0; i < 200; i++)
		p1(name, f, sgn(logu(0x1p-1074, 0x1p-3)));
	for (int i = 0; i < 50; i++)
		p1(name, f, sgn(logu(1.0000001, 1e10)));
	for (int i = 0; i < 200; i++)
		p1(name, f, randbits());
}

static void atan1(const char *name, fn1_t f)
{
	specials1(name, f);
	for (int e = -30; e <= 60; e++)
		for (int d = -1; d <= 1; d++)
			p1(name, f, sgn(next(ldexp(1.0, e), d)));
	for (int i = 0; i < 500; i++)
		p1(name, f, unif(-1, 1));
	for (int i = 0; i < 500; i++)
		p1(name, f, unif(-20, 20));
	for (int i = 0; i < 300; i++)
		p1(name, f, (float)unif(-100, 100));
	for (int i = 0; i < 300; i++)
		p1(name, f, sgn(logu(0x1p-1074, 0x1p-4)));
	for (int i = 0; i < 300; i++)
		p1(name, f, sgn(logu(16, 1e300)));
	for (int i = 0; i < 300; i++)
		p1(name, f, randbits());
}

static void atan2s(const char *name, fn2_t f)
{
	static const double s[] = {0.0, -0.0, INFINITY, -INFINITY, NAN, 1.0, -1.0, 0x1p-1074, -0x1p-1074, DBL_MIN,
		-DBL_MIN, DBL_MAX, -DBL_MAX, 1e-300, -1e-300, 1e300, -1e300, 2.5, -2.5};
	const int ns = (int)(sizeof(s) / sizeof(s[0]));
	for (int i = 0; i < ns; i++)
		for (int j = 0; j < ns; j++)
			p2(name, f, s[i], s[j]);
	for (int y = -6; y <= 6; y++) // integer grid incl. the axes
		for (int x = -6; x <= 6; x++)
			p2(name, f, y, x);
	for (int i = 0; i < 1500; i++) // vector components the engine passes (floats)
		p2(name, f, (float)unif(-1000, 1000), (float)unif(-1000, 1000));
	for (int i = 0; i < 500; i++) // unit vectors in float, as AnglesFromVectors sees them
	{
		float a = (float)unif(-1, 1), b = (float)unif(-1, 1);
		p2(name, f, a, b);
	}
	for (int i = 0; i < 600; i++) // ratios next to the 1/16 and 1 and 16 boundaries
	{
		double x = sgn(logu(1e-3, 1e3));
		double r = (i % 3 == 0) ? 0.0625 : (i % 3 == 1) ? 1.0 : 16.0;
		r *= unif(0.97, 1.03);
		p2(name, f, sgn(fabs(x) * r), x);
	}
	for (int i = 0; i < 800; i++)
		p2(name, f, unif(-1, 1), unif(-1, 1));
	for (int i = 0; i < 600; i++) // wide exponents: scaling and the de >= ep / de <= em shortcuts
		p2(name, f, sgn(logu(0x1p-1074, DBL_MAX)), sgn(logu(0x1p-1074, DBL_MAX)));
	for (int i = 0; i < 200; i++)
		p2(name, f, randbits(), randbits());
}

static void pows(const char *name, fn2_t f)
{
	static const double xs[] = {0.0, -0.0, INFINITY, -INFINITY, NAN, 1.0, -1.0, 0.5, -0.5, 2.0, -2.0, 10.0, -3.0,
		0x1p-1074, DBL_MAX, 0.999, 1.001};
	static const double ys[] = {0.0, -0.0, INFINITY, -INFINITY, NAN, 1.0, -1.0, 0.5, -0.5, 2.0, 3.0, -3.0, 0.25,
		1e10, -1e10, 1075.0, -1075.0, 1e-20, 0x1p53, 0x1p53 + 2};
	for (int i = 0; i < (int)(sizeof(xs) / sizeof(xs[0])); i++)
		for (int j = 0; j < (int)(sizeof(ys) / sizeof(ys[0])); j++)
			p2(name, f, xs[i], ys[j]);
	for (int i = 0; i < 1500; i++) // QuakeC pow (float, float)
		p2(name, f, (float)unif(0, 100), (float)unif(-10, 10));
	for (int i = 0; i < 500; i++) // curves.c: pow (area / 64, 0.25)
		p2(name, f, (float)logu(1e-6, 1e8), 0.25);
	for (int i = 0; i < 500; i++) // next to 1 with big exponents
		p2(name, f, 1.0 + sgn(logu(0x1p-52, 0x1p-4)), sgn(logu(1, 1e8)));
	for (int i = 0; i < 400; i++) // negative bases, integer exponents
		p2(name, f, -logu(1e-3, 1e3), (double)((int)(rnd64() % 81) - 40));
	for (int i = 0; i < 100; i++) // negative bases, non-integer exponents (nan)
		p2(name, f, -logu(1e-3, 1e3), unif(-5, 5));
	for (int i = 0; i < 800; i++)
		p2(name, f, logu(1e-30, 1e30), unif(-9, 9));
	for (int i = 0; i < 300; i++) // overflow / underflow / denormal results
		p2(name, f, logu(1.5, 1e4), sgn(unif(300, 1100)) / 0.5849625007211562);
	for (int i = 0; i < 300; i++)
		p2(name, f, logu(0x1p-1074, 0x1p-1000), unif(-1.2, 1.2));
	for (int i = 0; i < 200; i++)
		p2(name, f, randbits(), randbits());
}

static void logs(const char *name, fn1_t f)
{
	specials1(name, f);
	p1(name, f, 10.0);
	p1(name, f, M_E);
	for (int e = -1074; e <= 1023; e += 7)
		for (int d = -1; d <= 1; d++)
			p1(name, f, next(ldexp(1.0, e), d));
	for (int i = 0; i < 800; i++) // next to 1 (glibc has a separate path there)
		p1(name, f, 1.0 + sgn(logu(0x1p-53, 0x1p-3)));
	for (int i = 0; i < 300; i++)
		p1(name, f, unif(0.9, 1.1));
	for (int i = 0; i < 800; i++)
		p1(name, f, (float)logu(1e-30, 1e30));
	for (int i = 0; i < 800; i++)
		p1(name, f, logu(0x1p-1074, DBL_MAX));
	for (int i = 0; i < 100; i++)
		p1(name, f, -logu(1e-3, 1e3));
}

int main(void)
{
	__builtin_cpu_init();
	printf("V\t%s\n", gnu_get_libc_version());
	printf("CPU\t%d\t%d\n", __builtin_cpu_supports("fma") ? 1 : 0, __builtin_cpu_supports("avx2") ? 1 : 0);
	angles("sin", sin, 1);
	angles("cos", cos, 1);
	angles("tan", tan, 2);
	asincos("asin", asin);
	asincos("acos", acos);
	atan1("atan", atan);
	atan2s("atan2", atan2);
	pows("pow", pow);
	logs("log", log);
	for (int i = 0; i < NSPECIALS; i++)
		p1("sqrt", sqrt, specials[i]);
	for (int i = 0; i < 300; i++)
		p1("sqrt", sqrt, logu(0x1p-1074, DBL_MAX));
	for (int i = 0; i < 300; i++)
		p1("sqrt", sqrt, (float)logu(1e-10, 1e10));
	for (int i = 0; i < NSPECIALS; i++)
		for (int j = 0; j < NSPECIALS; j += 3)
			p2("fmod", fmod, specials[i], specials[j]);
	for (int i = 0; i < 300; i++)
		p2("fmod", fmod, sgn(logu(1e-10, 1e30)), sgn(logu(1e-10, 1e10)));
	return 0;
}
