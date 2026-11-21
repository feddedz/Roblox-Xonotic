/* Reference vectors for engine/_port/libc.luau from the real glibc (C locale).
   Build + run: tools/testgen/libc_vectors.sh > tests/vectors/libc.tsv
   Each line: hex(input) \t atof as hex double bits \t (float) bits \t (int)(float) \t atoi \t strtol value \t strtol end offset \t setvalue string */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

static const char *inputs[] = {
	"0", "1", "-1", "+1", "  42", "\t\n 3.5", "1.5abc", ".5", "5.", ".", "-.5e3", "1e", "1e+", "1e-2x",
	"0x10", "0x1p3", "0x1.8p1", "0x", "0xg", "0x.8", "-0x10.4", "inf", "-INF", "infinity", "infinit", "nan",
	"nan(123)", "NaN(", "abc", "", " ", "1 2 3", "800", "0.01388889", "3.402823466e38", "3.5e38", "1e400",
	"-1e400", "1e-50", "123456789", "2147483647", "2147483648", "-2147483648", "-2147483649", "4294967296",
	"9999999999999999999999", "16777217", "0.1", "0.2", "0.3", "1.0000001", "100.25", "-0", "-0.0",
	"0000012", "1e5", "2.5e-3", "12345.678", "7 cows", "   -  5", "--5", "+-5", "1,5", "0.000001",
	"0.0000001", "1234567.5", "8388608.5", "33554432", "1.17549435e-38", "1.4e-45", "0x7fffffff", "1e10",
	"-1e10", "65536", "0.999999", "0.9999999", "2.0000002", "1048576.1", "-3.75", "1e-7", "5e-324",
	"0.5000000000000001", "1.000000000000000000001", "6.02214076e23",
};

int main(void) {
	for (size_t k = 0; k < sizeof(inputs) / sizeof(inputs[0]); k++) {
		const char *s = inputs[k];
		double d = atof(s);
		float f = (float)d;
		volatile float vf = f;
		int fi = (int)vf; /* x86-64 cvttss2si */
		char *end;
		long l = strtol(s, &end, 10);
		uint64_t db; memcpy(&db, &d, 8);
		uint32_t fb; memcpy(&fb, &f, 4);
		char val[1024];
		if ((float)((int)vf) == vf) snprintf(val, sizeof(val), "%i", (int)vf);
		else snprintf(val, sizeof(val), "%f", vf);
		for (const char *p = s; *p; p++) printf("%02x", (unsigned char)*p);
		printf("\t%016llx\t%08x\t%d\t%d\t%ld\t%d\t%s\n", (unsigned long long)db, fb, fi, atoi(s), l, (int)(end - s), val);
	}
	return 0;
}
