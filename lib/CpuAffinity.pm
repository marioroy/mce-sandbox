###############################################################################
## ----------------------------------------------------------------------------
## CpuAffinity - Helper functions around taskset under Linux.
##
###############################################################################

package CpuAffinity;

use strict;
use warnings;

our $VERSION = '1.003'; $VERSION = eval $VERSION;

BEGIN {
   use Exporter();

   @CpuAffinity::ISA       = qw(Exporter);
   @CpuAffinity::EXPORT_OK = qw();

   @CpuAffinity::EXPORT    = qw(
      get_cpu_affinity set_cpu_affinity
   );
}

## Retrieve a process's CPU affinity.

sub get_cpu_affinity {

   my $pid = shift;
   return 0 if ($^O ne 'linux' or !defined $pid);

   my $taskset_cmd = "taskset --cpu-list --pid $pid";
   my $taskset_result = qx($taskset_cmd 2>/dev/null);

   return 0 if ($? != 0);

   $taskset_result =~ s/^[^:]+:\s*//;
   chomp($taskset_result);

   return $taskset_result;
}

## Set a process's CPU affinity. Returns 1 if successful.

sub set_cpu_affinity {

   my ($pid, $cpu_list_ref) = @_;
   return 0 if ($^O ne 'linux' or !defined $pid or !defined $cpu_list_ref);

   my $cpu_list = (ref $cpu_list_ref eq 'ARRAY')
                ? join(',', @$cpu_list_ref)
                : $cpu_list_ref;

   $cpu_list =~ s/\s\s*//g;
   if ($cpu_list =~ /^\d+$/) {
      my $current = get_cpu_affinity($pid);
      my @cpus;

      # Populate an array the process CPU affinity.
      while (length $current) {
         if ($current =~ /^,/) {
            substr $current, 0, 1, '';
         }
         elsif ($current =~ /^(\d+)-(\d+)/) {
            push @cpus, $_ for $1..$2;
            substr $current, 0, length("$1-$2"), '';
         }
         elsif ($current =~ /^(\d+)/) {
            push @cpus, $1;
            substr $current, 0, length("$1"), '';
         }
      }

      # Round-robin using the process CPU affinity.
      if (@cpus) {
          $cpu_list = $cpus[ $cpu_list % @cpus ];
      }
   }

   local $?;

   my $taskset_cmd = "taskset --cpu-list --pid $cpu_list $pid";
   my $taskset_result = qx($taskset_cmd 2>/dev/null);

   return ($? == 0) ? 1 : 0;
}

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

CpuAffinity - Helper functions around taskset under Linux

=head1 VERSION

This document describes CpuAffinity version 1.003

=head1 SYNOPSIS

This module exports 2 subroutines: get_cpu_affinity and set_cpu_affinity.

 use CpuAffinity;

 my $affinity = get_cpu_affinity($$);

 my $status = set_cpu_affinity($$, [1,3]);  # Returns 1 if successful
 my $status = set_cpu_affinity($$, [0,5,7,'9-11']);
 my $status = set_cpu_affinity($$, 0);

=head1 REQUIREMENTS

Linux Operating System

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2012-2023 by Mario E. Roy

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See L<http://dev.perl.org/licenses/> for more information.

=cut
