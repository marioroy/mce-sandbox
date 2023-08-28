#!/usr/bin/env perl
###############################################################################
## ----------------------------------------------------------------------------
## MCE script to count, sum, and generate prime numbers in order.
##
## Author: Mario Roy, <marioeroy@gmail.com>
##
###############################################################################

use strict;
use warnings;

use Cwd qw(abs_path);

my ($prog_name, $prog_dir, $base_dir, $threads_loaded);

BEGIN {
   $prog_name = $0;             $prog_name =~ s{^.*[\\/]}{}g;
   $prog_dir  = abs_path($0);   $prog_dir  =~ s{[\\/][^\\/]*$}{};
   $base_dir  = $prog_dir;      $base_dir  =~ s{[\\/][^\\/]*$}{};

   unshift @INC, "$base_dir/lib";
   $threads_loaded = 0;

   for (@ARGV) {
      if ($_ =~ /^--use-?threads/) {
         local $@; local $SIG{__DIE__} = sub { };
         eval 'use threads; use threads::shared';
         $threads_loaded = $@ ? 0 : 1;
         last;
      }
   }
}

## use bigint;

use Getopt::Long qw(:config bundling no_ignore_case no_auto_abbrev);
use Scalar::Util qw(looks_like_number);
use Time::HiRes  qw(sleep time);
use CpuAffinity;

use MCE::Signal  qw($tmp_dir -use_dev_shm);
use MCE;

use Sandbox;

###############################################################################
## ----------------------------------------------------------------------------
## Display usage and exit.
##
###############################################################################

sub usage()
{
   print STDERR <<"::_USAGE_BLOCK_END_::";

NAME
   $prog_name -- count, sum, or generate prime numbers in order

SYNOPISIS
   $prog_name [options] [[ FROM ] NUMBER ]

DESCRIPTION
   The $prog_name utility is a parallel sieve generator. Primes are
   generated by the primesieve.org C API.

   It generates 50,847,534 primes in little time. Notice the file size for
   primes.out. This will obviously consume lots of space; e.g. running with
   1e+11 requires 45.5 GB. The upper limit for number is 2^64-1-6.

   $prog_name 1e9 --print > primes.out   # file size 479 MB

   $prog_name 4294967296                 # default, count primes
   203280221

   $prog_name 4294967296 --sum           # sum primes
   425649736193687430

   The following options are available:

   --maxworkers=<val>   specify the number of workers (default 100%)
   --threads=<val>      alias for --maxworkers
   --usethreads         spawn workers via threads if available (not fork)
   --help,  -h          display this help and exit
   --print, -p          print primes (ignored if sum is specified)
   --quiet, -q          suppress progress including extra output
   --sum,   -s          sum primes (maximum N allowed 29505444490)

EXAMPLES
   $prog_name 18446744073000000000 18446744073709551609
   $prog_name --maxworkers=8 1000000000
   $prog_name --threads=50% 1e+16 1.00001e+16
   $prog_name 22801763489 --sum
   $prog_name 1e5 3e5 --print

EXIT STATUS
   The $prog_name utility exits with one of the following values:

   0    a prime was found
   1    a prime was not found
   >1   an error occurred

::_USAGE_BLOCK_END_::

   exit 2;
}

###############################################################################
## ----------------------------------------------------------------------------
## Define defaults. Process command-line options.
##
###############################################################################

my ($print_flag, $quiet_flag, $sum_flag, $run_mode) = (0, 0, 0, MODE_COUNT);

my $max_workers = '100%';
my $max_number  = 18446744073709551609;   ## 2^64-1-6
my $use_threads = 0;

{
   no warnings;
   my $help_flag = 0; local $@;

   my $result = GetOptions(
      'maxworkers|max-workers|threads=s' => \$max_workers,
      'usethreads|use-threads' => \$use_threads,
      'h|help'  => \$help_flag,
      'p|print' => \$print_flag,
      'q|quiet' => \$quiet_flag,
      's|sum'   => \$sum_flag
   );

   $use_threads = 0
      if $use_threads and not $threads_loaded;

   usage() if not $result;
   usage() if $help_flag;

   if ($max_workers !~ /^auto/ && $max_workers !~ /^[0-9.]+%$/) {
      if (not looks_like_number($max_workers) && $max_workers > 0) {
         print STDERR "$prog_name: $max_workers: invalid max workers\n";
         exit 2;
      }
   }

   usage() unless defined $ARGV[0];

   $run_mode = MODE_PRINT if $print_flag;
   $run_mode = MODE_SUM   if $sum_flag;
}

## Validation.

$max_workers = MCE::_parse_max_workers($max_workers);

my $F_arg = (defined $ARGV[1]) ? $ARGV[0] : 1;
my $N_arg = (defined $ARGV[1]) ? $ARGV[1] : $ARGV[0];

{
   local $@; no warnings;
   $F_arg = sprintf("%s", eval $F_arg);
   $N_arg = sprintf("%s", eval $N_arg);
}

Sandbox::check_numbers($prog_name, $max_number, $F_arg, $N_arg, $sum_flag);

my $F = $F_arg + 0;
my $N = $N_arg + 0;

###############################################################################
## ----------------------------------------------------------------------------
## Include C functions.
##
## Specifying -std=c99 fails under the Windows environment due to several
## header files not c99 compliant. The -march=native option is not supported
## by the MinGW compiler. Update ExtUtils::MakeMaker if compiling fails
## under Cygwin. Specify CCFLAGSEX, not CCFLAGS.
##
###############################################################################

my ($_cc_flgs, $_lib_flgs);

BEGIN {
   $ENV{PERL_INLINE_DIRECTORY} = "${base_dir}/.Inline";
   mkdir "${base_dir}/.Inline" unless -d "${base_dir}/.Inline";

   $_cc_flgs  = "-I/usr/local/include -I${base_dir}/src";
   $_lib_flgs = "-L/usr/local/lib64 -L/usr/local/lib -lprimesieve";
}

use Inline 'C' => Config => LIBS => "${_lib_flgs}" =>
   CCFLAGSEX => "${_cc_flgs} -O3 -fomit-frame-pointer",
   TYPEMAPS => "${base_dir}/src/typemap",
   clean_after_build => 0;

use Inline 'C' => "${base_dir}/src/primesieve.c";

###############################################################################
## ----------------------------------------------------------------------------
## Instantiate a MCE instance.
##
###############################################################################

my $ncpu = MCE::Util->get_ncpu();

my $step_size = 9609600 * ($run_mode == MODE_PRINT ? 1 : 19) * do {
   if    ($N >= 1e+19) { 8; }
   elsif ($N >= 1e+18) { 7; }
   elsif ($N >= 1e+17) { 6; }
   elsif ($N >= 1e+16) { 5; }
   elsif ($N >= 1e+15) { 4; }
   elsif ($N >= 1e+14) { 3; }
   elsif ($N >= 1e+13) { 2; }
   elsif ($N >= 1e+12) { 1; }
   else                { 1; }
};

my $mce = MCE->new(
   gather      => Sandbox::o_iter($F, $N, $quiet_flag, $run_mode),
   input_data  => Sandbox::i_iter($F, $N, $step_size),
   max_workers => (($F == $N) ? 1 : $max_workers),
   use_threads => $use_threads,
   init_relay  => 1,

   user_begin => sub {
      my ($mce, $task_id, $task_name) = @_;
      set_cpu_affinity($$, ($mce->task_wid() - 1) % $ncpu)
         if ($mce->max_workers > 2 && !$use_threads);
   },

   user_func => sub {
      my ($mce, $chunk_ref, $chunk_id) = @_;
      my ($low, $output_fd, $output_fh) = ($chunk_ref->[0], 0);

      if ($run_mode == MODE_PRINT) {
         open $output_fh, ">", "$tmp_dir/$chunk_id" or
            die "$prog_name: cannot open '$tmp_dir/$chunk_id' for writing\n";

         $output_fd = fileno $output_fh;
      }

      my $high = ($max_number - $low <= $step_size)
         ? $N : Sandbox::min($low + $step_size - 1, $N);

      my $p = primesieve($low, $high, $run_mode, $output_fd);

      if ($run_mode == MODE_PRINT) {
         close $output_fh;
         MCE::relay { Sandbox::display($chunk_id, "$tmp_dir/$chunk_id") };
         MCE->gather($chunk_id, $high, $mce->wid);
         MCE->abort() if ($p->[0] < 0);
      }
      else {
         MCE->gather($p->[0], $high, $mce->wid);
      }

      return;
   }
);

###############################################################################
## ----------------------------------------------------------------------------
## Run.
##
###############################################################################

syswrite(\*STDERR, "  0%\r") unless $quiet_flag;
my $start = time();

# disable threading in the primesieve library
primesieve_disable_threading();

$mce->run();

exit(Sandbox::end($quiet_flag, $run_mode, time() - $start));
