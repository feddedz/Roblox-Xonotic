/* Prints glibc strftime (C locale, gmtime) results: time_t<TAB>conversion<TAB>result. */
#include <stdio.h>
#include <time.h>
int main(void) {
	long long ts[] = {0, 951782400LL, 1104537600LL, 1230681600LL, 1293753600LL, 1700000000LL, 1735603199LL,
	                  1798675200LL, 2000000000LL, 1609459200LL, 1641024000LL};
	const char *convs = "aAbBcCdDeFgGhHIjklmMnpPrRsStTuUVwWxXyYzZ%";
	for (size_t k = 0; k < sizeof(ts) / sizeof(ts[0]); k++) {
		time_t t = (time_t)ts[k];
		struct tm *tm = gmtime(&t);
		for (const char *c = convs; *c; c++) {
			char fmt[3] = {'%', *c, 0}, out[256];
			strftime(out, sizeof(out), fmt, tm);
			printf("%lld\t%c\t", ts[k], *c);
			for (char *p = out; *p; p++) printf("%02x", (unsigned char)*p);
			printf("\n");
		}
	}
	return 0;
}
