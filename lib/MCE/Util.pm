###############################################################################
## ----------------------------------------------------------------------------
## MCE::Util - Public and private utility functions for Many-core Engine.
##
###############################################################################

package MCE::Util;

use strict;
use warnings;

use base qw( Exporter );
use bytes;

our $VERSION = '1.519'; $VERSION = eval $VERSION;

our @EXPORT_OK = qw( get_ncpu );
our %EXPORT_TAGS = ( all => \@EXPORT_OK );

###############################################################################
## ----------------------------------------------------------------------------
## The get_ncpu subroutine, largely adopted from Test::Smoke::Util.pm,
## returns the number of logical (online/active/enabled) CPU cores;
## never smaller than one.
##
## A warning is emitted to STDERR when it cannot recognize the operating
## system or the external command failed.
##
###############################################################################

my $g_ncpu;

sub get_ncpu {

   return $g_ncpu if (defined $g_ncpu);

   local $ENV{PATH} = "/usr/sbin:/sbin:/usr/bin:/bin:$ENV{PATH}";

   my $ncpu = 1;

   OS_CHECK: {
      local $_ = $^O;

      /linux/i && do {
         my $count; local *PROC;
         if ( open PROC, "< /proc/stat" ) {
             $count = grep /^cpu\d/ => <PROC>;
             close PROC;
         }
         $ncpu = $count if $count;
         last OS_CHECK;
      };

      /bsd|darwin|dragonfly/i && do {
         chomp( my @output = `sysctl -n hw.ncpu 2>/dev/null` );
         $ncpu = $output[0] if @output;
         last OS_CHECK;
      };

      /aix/i && do {
         my @output = `pmcycles -m 2>/dev/null`;
         if (@output) {
            $ncpu = scalar @output;
         } else {
            @output = `lsdev -Cc processor -S Available 2>/dev/null`;
            $ncpu = scalar @output if @output;
         }
         last OS_CHECK;
      };

      /hp-?ux/i && do {
         my $count = grep /^processor/ => `ioscan -fkC processor 2>/dev/null`;
         $ncpu = $count if $count;
         last OS_CHECK;
      };

      /irix/i && do {
         my @output = grep /\s+processors?$/i => `hinv -c processor 2>/dev/null`;
         $ncpu = (split " ", $output[0])[0] if @output;
         last OS_CHECK;
      };

      /osf|solaris|sunos|svr5|sco/i && do {
         if (-x '/usr/sbin/psrinfo') {
            my $count = grep /on-?line/ => `psrinfo 2>/dev/null`;
            $ncpu = $count if $count;
         }
         else {
            my @output = grep /^NumCPU = \d+/ => `uname -X 2>/dev/null`;
            $ncpu = (split " ", $output[0])[2] if @output;
         }
         last OS_CHECK;
      };

      /mswin|mingw|cygwin/i && do {
         $ncpu = $ENV{NUMBER_OF_PROCESSORS}
            if exists $ENV{NUMBER_OF_PROCESSORS};
         last OS_CHECK;
      };

      warn "MCE::Util::get_ncpu: command failed or unknown operating system\n";
   }

   return $g_ncpu = $ncpu;
}

###############################################################################
## ----------------------------------------------------------------------------
## Private methods.
##
###############################################################################

sub _parse_max_workers {

   my ($_max_workers) = @_;

   return $_max_workers
      unless (defined $_max_workers);

   if ($_max_workers =~ /^auto(?:$|\s*([\-\+\/\*])\s*(.+)$)/i) {
      my $_ncpu = get_ncpu();

      if ($1 && $2) {
         local $@; $_max_workers = eval "int($_ncpu $1 $2 + 0.5)";
         $_max_workers = 1 if (!$_max_workers || $_max_workers < 1);
      }
      else {
         $_max_workers = $_ncpu;
      }
   }

   return $_max_workers;
}

sub _parse_chunk_size {

   my ($_chunk_size, $_max_workers, $_params, $_input_data, $_array_size) = @_;

   return $_chunk_size
      if (!defined $_chunk_size || !defined $_max_workers);

   $_chunk_size = $_params->{chunk_size}
      if (defined $_params && exists $_params->{chunk_size});

   if ($_chunk_size =~ /([0-9\.]+)K\z/i) {
      $_chunk_size = int($1 * 1024 + 0.5);
   }
   elsif ($_chunk_size =~ /([0-9\.]+)M\z/i) {
      $_chunk_size = int($1 * 1024 * 1024 + 0.5);
   }

   if ($_chunk_size eq 'auto') {
      my $_size = (defined $_input_data && ref $_input_data eq 'ARRAY')
         ? scalar @{ $_input_data } : $_array_size;

      my $_is_file;

      if (defined $_params && exists $_params->{sequence}) {
         my ($_begin, $_end, $_step);

         if (ref $_params->{sequence} eq 'HASH') {
            $_begin = $_params->{sequence}->{begin};
            $_end   = $_params->{sequence}->{end};
            $_step  = $_params->{sequence}->{step} || 1;
         }
         else {
            $_begin = $_params->{sequence}->[0];
            $_end   = $_params->{sequence}->[1];
            $_step  = $_params->{sequence}->[2] || 1;
         }

         $_size = abs($_end - $_begin) / $_step + 1
            if (!defined $_input_data && !$_array_size);
      }
      elsif (defined $_params && exists $_params->{_file}) {
         my $_ref = ref $_params->{_file};

         if ($_ref eq 'SCALAR') {
            $_size = length ${ $_params->{_file} };
         } elsif ($_ref eq '') {
            $_size = -s $_params->{_file};
         } else {
            $_size = 0; $_chunk_size = 245760;
         }

         $_is_file = 1;
      }
      elsif (defined $_input_data) {
         if (ref $_input_data eq 'GLOB' || ref($_input_data) =~ /^IO::/) {
            $_is_file = 1; $_size = 0; $_chunk_size = 245760;
         }
         elsif (ref $_input_data eq 'SCALAR') {
            $_is_file = 1; $_size = length $$_input_data;
         }
      }

      if (defined $_is_file) {
         if ($_size) {
            $_chunk_size = int($_size / $_max_workers / 24 + 0.5);
            $_chunk_size = 4194304 if $_chunk_size > 4194304;  ## 4M
            $_chunk_size = 2 if $_chunk_size <= 8192;
         }
      }
      else {
         $_chunk_size = int($_size / $_max_workers / 24 + 0.5);
         $_chunk_size = 8000 if $_chunk_size > 8000;
         $_chunk_size = 2 if $_chunk_size < 2;
      }
   }

   return $_chunk_size;
}

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Util - Public and private utility functions for Many-core Engine

=head1 VERSION

This document describes MCE::Util version 1.519

=head1 SYNOPSIS

 use MCE::Util;

=head1 DESCRIPTION

A utility module for MCE. Nothing is exported by default. Exportable is
get_ncpu.

=head2 get_ncpu()

Returns the number of logical (online/active/enabled) CPU cores; never smaller
than one.

 my $ncpu = MCE::Util::get_ncpu();

Specifying 'auto' for max_workers calls MCE::Util::get_ncpu automatically.

 use MCE;

 my $mce = MCE->new(
   max_workers => 'auto-1',        ## MCE::Util::get_ncpu() - 1
   max_workers => 'auto+3',        ## MCE::Util::get_ncpu() + 3
   max_workers => 'auto',          ## MCE::Util::get_ncpu()
 );

=head1 ACKNOWLEDGEMENTS

The portable code for detecting the number of processors was adopted from
L<Test::Smoke::SysInfo>.

=head1 INDEX

L<MCE>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=head1 LICENSE

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See L<http://dev.perl.org/licenses/> for more information.

=cut

