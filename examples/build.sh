#!/bin/bash -x
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Ensure 'gcc', 'codon', and 'nvcc' executables are in your path.
# Specify the full path otherwise.
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

NVCC="nvcc"
CODON="codon"
CC="gcc"

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Uncomment the items you wish to build.
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# ${NVCC} -o cudasieve -I../src -O3 -prec-sqrt=true cudasieve.cu -lm

# ${CODON} build -release -o cpusieve cpusieve.codon
# ${CODON} build -release -o gpusieve gpusieve.codon
# ${CODON} build -release -o pgpusieve pgpusieve.codon

  ${CC} -o practicalsieve -I../src -O3 practicalsieve.c -lm
  ${CC} -o prangesieve -I../src -O3 -fopenmp prangesieve.c -lm
  ${CC} -o rangesieve -I../src -O3 rangesieve.c -lm
  ${CC} -o segmentsieve -I../src -O3 segmentsieve.c -lm

