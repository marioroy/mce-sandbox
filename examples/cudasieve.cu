
// Algorithm3 (parallel range variant).
//   CUDA demonstration by Mario Roy, 2023-09-10
//
// Xuedong Luo:
//   A practical sieve algorithm for finding prime numbers.
//   ACM Volume 32 Issue 3, March 1989, Pages 344-346
//   https://dl.acm.org/doi/pdf/10.1145/62065.62072
//   http://dl.acm.org/citation.cfm?doid=62065.62072
//
//   "Based on the sieve of Eratosthenes, a faster and more compact
//    algorithm is presented for finding all primes between 2 and N.
//    Avoid all composites that have 2 or 3 as one of their prime
//    factors (where i is odd)."
//
//   { 0, 5, 7, 11, 13, ... 3i + 2, 3(i + 1) + 1, ..., N }
//     0, 1, 2,  3,  4, ... list indices (0 is not used)
//
// Build:
//   nvcc -o cudasieve -I../src -O3 -prec-sqrt=true cudasieve.cu -lm
//
// Usage:
//   cudasieve [ N [ N ] [ -p ] ]  default 1 1000
//   cudasieve 100 -p              print primes found
//   cudasieve 1e+10 1.1e+10       count primes found
//   cudasieve 87233720365000000 87233720368547757
//   cudasieve 1e12 1.1e12

#include <cuda_runtime.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include <time.h>
#include "bits.h"

#define CUDACHECK(err) do { cuda_check((err), __FILE__, __LINE__); } while (false)
inline void cuda_check(cudaError_t error_code, const char *file, int line)
{
   if (error_code != cudaSuccess) {
      fprintf(stderr, "CUDA Error %d: %s. In file '%s' on line %d\n",
         error_code, cudaGetErrorString(error_code), file, line);
      fflush(stderr), exit(error_code);
   }
}

byte_t *makeprimes(uint64_t stop)
{
   int64_t q = (int64_t) sqrt((double) stop) / 3;
   int64_t mem_sz = (q + 2 + 7) / 8;
   int64_t i, c = 0, k = 1, t = 2, j, ij;

   byte_t *array = (byte_t *) malloc(mem_sz);
   if (array == NULL) {
      fprintf(stderr, "error: failed to allocate primes array.\n");
      exit(2);
   }
   memset(array, 0xff, mem_sz);
   CLRBIT(array, 0);

   // clear small composites <= q
   for (i = 1; i <= q; i++) {
      k = 3 - k, c += 4 * k * i, j = c;
      ij = 2 * i * (3 - k) + 1, t += 4 * k;
      if (GETBIT(array, i)) {
         while (j <= q) {
            CLRBIT(array, j);
            j += ij, ij = t - ij;
         }
      }
   }

   return array;
}

__global__ static void gpusieve_32(
   byte_t *sieve, const byte_t *is_prime, int64_t step_sz,
   int64_t num_segments, uint64_t start_adj, uint64_t stop, int64_t j_off )
{
   const unsigned int n = __umul24(blockDim.x, blockIdx.x) + threadIdx.x;
   if (n >= num_segments) return;

   static const byte_t unset_bit[8] = {
      (~(1 << 0) & 0xff), (~(1 << 1) & 0xff),
      (~(1 << 2) & 0xff), (~(1 << 3) & 0xff),
      (~(1 << 4) & 0xff), (~(1 << 5) & 0xff),
      (~(1 << 6) & 0xff), (~(1 << 7) & 0xff)
   };

   // account for one-byte padding between segments
   uint32_t s_off = j_off - n * 8, j_off2;
   if (n == 0) { 
      j_off2 = (uint32_t) j_off;
   } else {
      uint64_t low_ = start_adj + step_sz * (n - 1);
      uint64_t high_ = low_ + step_sz - 1;
      if (high_ > stop || high_ < low_) high_ = stop;
      j_off2 = (uint32_t) (high_ / 3);
   }

   // sieve primes
   uint64_t low = start_adj + (step_sz * n);
   uint64_t high = low + step_sz - 1;
   if (high > stop || high < low) high = stop;

   uint32_t c = 0, k = 1, t = 2, j, ij;
   uint32_t n1 = 1, n2 = 2, n3 = 3, n4 = 4;
   uint32_t q = (uint32_t) (sqrt((double) high) / 3);
   uint32_t m = (uint32_t) (high / 3);
   m -= s_off;

   for (uint32_t i = n1; i <= q; i++) {
      k = n3 - k, c += n4 * k * i, j = c;
      ij = n2 * i * (n3 - k) + n1, t += n4 * k;
      if (GETBIT(is_prime, i)) {
         // skip numbers before this segment
         if (j < j_off2) {
            j += (j_off2 - j) / t * t + ij;
            ij = t - ij;
            if (j < j_off2)
               j += ij, ij = t - ij;
         }
         // clear composites
         j -= s_off;
         while (j <= m) {
            sieve[j >> 3] &= unset_bit[j & 7];
            j += ij, ij = t - ij;
         }
      }
   }
}

__global__ static void gpusieve_64(
   byte_t *sieve, const byte_t *is_prime, int64_t step_sz,
   int64_t num_segments, uint64_t start_adj, uint64_t stop, int64_t j_off )
{
   const unsigned int n = __umul24(blockDim.x, blockIdx.x) + threadIdx.x;
   if (n >= num_segments) return;

   static const byte_t unset_bit[8] = {
      (~(1 << 0) & 0xff), (~(1 << 1) & 0xff),
      (~(1 << 2) & 0xff), (~(1 << 3) & 0xff),
      (~(1 << 4) & 0xff), (~(1 << 5) & 0xff),
      (~(1 << 6) & 0xff), (~(1 << 7) & 0xff)
   };

   // account for one-byte padding between segments
   int64_t s_off = j_off - n * 8, j_off2;
   if (n == 0) { 
      j_off2 = j_off;
   } else {
      uint64_t low_ = start_adj + step_sz * (n - 1);
      uint64_t high_ = low_ + step_sz - 1;
      if (high_ > stop || high_ < low_) high_ = stop;
      j_off2 = high_ / 3;
   }

   // sieve primes
   uint64_t low = start_adj + (step_sz * n);
   uint64_t high = low + step_sz - 1;
   if (high > stop || high < low) high = stop;

   int64_t c = 0, j; uint32_t k = 1, t = 2, ij;
   uint32_t n1 = 1, n2 = 2, n3 = 3, n4 = 4;
   uint32_t q = (uint32_t) (sqrt((double) high) / 3);
   int64_t m = high / 3;
   m -= s_off;

   for (int32_t i = n1; i <= q; i++) {
      k = n3 - k, c += n4 * k * i, j = c;
      ij = n2 * i * (n3 - k) + n1, t += n4 * k;
      if (GETBIT(is_prime, i)) {
         // skip numbers before this segment
         if (j < j_off2) {
            j += (j_off2 - j) / t * t + ij;
            ij = t - ij;
            if (j < j_off2)
               j += ij, ij = t - ij;
         }
         // clear composites
         j -= s_off;
         while (j <= m) {
            sieve[j >> 3] &= unset_bit[j & 7];
            j += ij, ij = t - ij;
         }
      }
   }
}

void cudasieve(uint64_t start, uint64_t stop, int print_flag)
{
   // adjust start to a multiple of 6; then subtract 6 and add 1
   uint64_t start_adj = (start > 5)
      ? start - (start % 6) - 6 + 1
      : 1;

   int64_t bsize, step_sz;

   if (stop < 1e11)
      { bsize =  4, step_sz = 39600; }
   else if (stop < 1e14)
      { bsize =  8, step_sz = 39600; }
   else if (stop < 1e16)
      { bsize = 16, step_sz = 39600 * 3; }
   else
      { bsize = 32, step_sz = 39600 * 5; }

   if      ( stop >= 1e+19 ) { step_sz *= 80; }
   else if ( stop >= 1e+18 ) { step_sz *= 70; }
   else if ( stop >= 1e+17 ) { step_sz *= 60; }
   else if ( stop >= 1e+16 ) { step_sz *= 50; }
   else if ( stop >= 1e+15 ) { step_sz *= 40; }
   else if ( stop >= 1e+14 ) { step_sz *= 30; }
   else if ( stop >= 1e+13 ) { step_sz *= 20; }
   else if ( stop >= 1e+12 ) { step_sz *= 10; }

   int64_t num_segments = (stop - start_adj + step_sz) / step_sz;
   byte_t *is_prime = makeprimes(stop);
   int64_t count = 0;

   int64_t M = (stop - start_adj + (stop & 1)) / 3;
   uint64_t n_off = start_adj - 1;
   int64_t j_off = n_off / 3;
   int64_t mem_sz = (M + 2 + 7) / 8 + (num_segments - 1);
   byte_t *sieve;

   sieve = (byte_t *) malloc(mem_sz);
   if (sieve == NULL) {
      fprintf(stderr, "error: failed to allocate sieve array.\n");
      exit(2);
   }
   memset(sieve, 0xff, mem_sz);
   CLRBIT(sieve, 0);

   // clear bits less than start
   if (n_off + ((3 * 1 + 1) | 1) < start) {
      CLRBIT(sieve, 1);
      if (n_off + ((3 * 2 + 1) | 1) < start)
         CLRBIT(sieve, 2);
   }

   // clear bits greater than stop
   int64_t i = (mem_sz - (num_segments - 1)) * 8 - (M + 2);
   while (i) {
      CLRBIT(sieve, mem_sz * 8 - i);
      i--;
   }
   if (n_off + ((3 * (M + 1) + 1) | 1) > stop) {
      CLRBIT(sieve, M + 1 + (num_segments - 1) * 8);
      if (n_off + ((3 * M + 1) | 1) > stop)
         CLRBIT(sieve, M + (num_segments - 1) * 8);
   }

   // create MM list; clear one-byte padding between segments
   int64_t *MM = (int64_t *) malloc(num_segments * sizeof(int64_t));
   int64_t off = 0;

   for (int64_t n = 0; n < num_segments - 1; n++) {
      uint64_t low = start_adj + (step_sz * n);
      uint64_t high = low + step_sz - 1;
      if (high > stop || high < low) high = stop;
      int64_t m = high / 3;
      MM[n] = m - j_off;
      for (int i = 1; i <= 8; i++)
         CLRBIT(sieve, m - j_off + i + off);
      off += 8;
   }

   MM[num_segments - 1] = M + 2;
   int64_t gsize = num_segments / bsize + (num_segments % bsize ? 1 : 0);

   // ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
   // CUDA BEGIN //////////////////////////////////////////////////////////////
   // ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

   // init CUDA, change integer on a multi-GPU system
   CUDACHECK(cudaSetDevice(0));
 
   int64_t q = (int64_t) sqrt((double) stop) / 3;
   int64_t mem_sz_p = (q + 2 + 7) / 8;

   byte_t *d_is_prime = NULL;  // size mem_sz_p
   byte_t *d_sieve = NULL;     // size mem_sz
   float kernel_time;

   // allocate memory on the device
   CUDACHECK(cudaMalloc((void**) &d_is_prime, sizeof(byte_t) * mem_sz_p));
   CUDACHECK(cudaMalloc((void**) &d_sieve, sizeof(byte_t) * mem_sz));

   // copy -> device
   CUDACHECK(cudaMemcpy(d_is_prime, is_prime, sizeof(byte_t) * mem_sz_p, cudaMemcpyHostToDevice));
   CUDACHECK(cudaMemcpy(d_sieve, sieve, sizeof(byte_t) * mem_sz, cudaMemcpyHostToDevice));

   // run the kernel
   cudaEvent_t kernel_start, kernel_stop;
   cudaEventCreate(&kernel_start);
   cudaEventCreate(&kernel_stop);
   cudaEventRecord(kernel_start, 0);

   if (stop <= 12700000000)  // 1.27e10
      gpusieve_32<<<gsize, bsize, 0>>>( d_sieve, d_is_prime,
         step_sz, num_segments, start_adj, stop, j_off );
   else
      gpusieve_64<<<gsize, bsize, 0>>>( d_sieve, d_is_prime,
         step_sz, num_segments, start_adj, stop, j_off );

   cudaDeviceSynchronize();
   cudaEventRecord(kernel_stop, 0);
   cudaEventSynchronize(kernel_stop);
   cudaEventElapsedTime(&kernel_time, kernel_start, kernel_stop);
   cudaEventDestroy(kernel_start);
   cudaEventDestroy(kernel_stop);

   // copy -> host
   CUDACHECK(cudaMemcpy(sieve, d_sieve, sizeof(byte_t) * mem_sz, cudaMemcpyDeviceToHost));

   // release memory
   cudaFree(d_sieve);
   cudaFree(d_is_prime);

   // ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
   // CUDA END ////////////////////////////////////////////////////////////////
   // ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

   free((void *) is_prime); is_prime = NULL;

   if (start <= 2 && stop >= 2) count++;
   if (start <= 3 && stop >= 3) count++;

   count += popcount(sieve, mem_sz);

   if (print_flag) {
      if (start <= 2 && stop >= 2) printf("2\n");
      if (start <= 3 && stop >= 3) printf("3\n");
      int64_t off = 0, num = MM[0], ind = 0;
      for (i = 1; i <= M; i += 2) {
         if (i >= num)
            off += 8, num = MM[++ind];
         if (GETBIT(sieve, i + off))
            printf("%lu\n", n_off + (3 * i + 2));
         if (GETBIT(sieve, i + 1 + off))
            printf("%lu\n", n_off + (3 * (i + 1) + 1));
      }
   }

   free((void *) MM); MM = NULL;
   free((void *) sieve); sieve = NULL;

   fprintf(stderr, "Primes found: %ld\n", count);
   fprintf(stderr, " Kernel time: %0.3lf\n", kernel_time / 1000);
}

int main(int argc, char** argv)
{
   // find primes in range, inclusively
   uint64_t start = 1, stop = 1000;
   int print_flag = 0;

   // check for print option (last option specified)
   if (argc > 1 && strcmp(argv[argc-1], "-p") == 0) {
      print_flag = 1;
      argc--;
   }

   if (argc > 2) {
      start = (uint64_t) strtold(argv[1], NULL);
      stop  = (uint64_t) strtold(argv[2], NULL);
   }
   else if (argc > 1) {
      stop  = (uint64_t) strtold(argv[1], NULL);
   }

   if (stop > 0 && stop >= start) {
      if (stop - start > 1e+11) {
         fprintf(stderr, "Range distance exceeds 1e+11 (~4GB).\n");
         return 1;
      }

      clock_t tstart = clock();
      cudasieve(start, stop, print_flag);
      clock_t tend = clock();

      double elapsed_time = ((double) (tend - tstart)) / CLOCKS_PER_SEC;
      fprintf(stderr, "  Total time: %0.3lf\n", elapsed_time);
   }

   return 0;
}

