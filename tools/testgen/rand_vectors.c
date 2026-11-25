/* Prints glibc srand/rand sequences: seed<TAB>first 40 rand() values (comma-separated). */
#include <stdio.h>
#include <stdlib.h>
int main(void) {
	unsigned seeds[] = {0, 1, 2, 42, 1234567890u, 2147483647u, 2147483648u, 4294967295u, 1700000000u};
	for (size_t k = 0; k < sizeof(seeds) / sizeof(seeds[0]); k++) {
		srand(seeds[k]);
		printf("%u\t", seeds[k]);
		for (int i = 0; i < 40; i++) printf(i ? ",%d" : "%d", rand());
		printf("\n");
	}
	return 0;
}
