/* glibc printf of one conversion: flags<TAB>width<TAB>prec<TAB>conv<TAB>value<TAB>hex(result).
   Integer values are intmax_t ("%j"), floats double. Used by tests/unit/libc.test.luau (libc.format1). */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
static void hex(const char *s) { for (; *s; s++) printf("%02x", (unsigned char)*s); printf("\n"); }
int main(void) {
	const char *flags[] = {"", "-", "0", "+", " ", "#", "-0", "+0", "#0", "- +"};
	int widths[] = {0, 1, 5, 12, 120};
	int precs[] = {-1, 0, 3, 110};
	long long ivals[] = {0, 1, -1, 42, -42, 255, 2147483647LL, -2147483648LL, 4294967296LL, -9223372036854775807LL - 1};
	double dvals[] = {0.0, -0.0, 1.0, -1.5, 3.14159265, 1e10, 1.25e-7, 123456789.0, INFINITY, -INFINITY, NAN, 0.000123};
	const char *iconvs = "dxXou", *dconvs = "efgEG";
	char fmt[64], out[1024];
	for (size_t f = 0; f < sizeof(flags) / sizeof(*flags); f++)
	for (size_t w = 0; w < sizeof(widths) / sizeof(*widths); w++)
	for (size_t p = 0; p < sizeof(precs) / sizeof(*precs); p++) {
		const char *pre = precs[p] >= 0 ? ".*" : "";
		for (const char *c = iconvs; *c; c++)
		for (size_t v = 0; v < sizeof(ivals) / sizeof(*ivals); v++) {
			snprintf(fmt, sizeof fmt, "%%%s*%sj%c", flags[f], pre, *c);
			if (precs[p] >= 0) snprintf(out, sizeof out, fmt, widths[w], precs[p], (intmax_t)ivals[v]);
			else snprintf(out, sizeof out, fmt, widths[w], (intmax_t)ivals[v]);
			printf("%s\t%d\t%d\t%c\t%lld\t", flags[f], widths[w], precs[p], *c, ivals[v]); hex(out);
		}
		if (precs[p] > 99) continue;
		for (const char *c = dconvs; *c; c++)
		for (size_t v = 0; v < sizeof(dvals) / sizeof(*dvals); v++) {
			snprintf(fmt, sizeof fmt, "%%%s*%s%c", flags[f], pre, *c);
			if (precs[p] >= 0) snprintf(out, sizeof out, fmt, widths[w], precs[p], dvals[v]);
			else snprintf(out, sizeof out, fmt, widths[w], dvals[v]);
			printf("%s\t%d\t%d\t%c\t%a\t", flags[f], widths[w], precs[p], *c, dvals[v]); hex(out);
		}
	}
	return 0;
}
