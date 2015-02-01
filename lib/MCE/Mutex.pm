###############################################################################
## ----------------------------------------------------------------------------
## MCE::Mutex - Simple semaphore for Many-Core Engine.
##
###############################################################################

package MCE::Mutex;

use strict;
use warnings;

use Socket qw( :crlf PF_UNIX PF_UNSPEC SOCK_STREAM );

our $VERSION = '1.600';

sub DESTROY {

   my ($_mutex) = @_;

   return if (defined $MCE::MCE && $MCE::MCE->wid);

   if (defined $_mutex->{_r_sock}) {
      local ($!, $?);

      CORE::shutdown $_mutex->{_w_sock}, 2;
      CORE::shutdown $_mutex->{_r_sock}, 2;

      close $_mutex->{_w_sock}; undef $_mutex->{_w_sock};
      close $_mutex->{_r_sock}; undef $_mutex->{_r_sock};
   }

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## New instance instantiation.
##
###############################################################################

sub new {

   my ($_class, %_argv) = @_;

   @_ = (); local $!;

   return if (defined $MCE::MCE && $MCE::MCE->wid);

   my $_mutex = {}; bless($_mutex, ref($_class) || $_class);

   socketpair( $_mutex->{_r_sock}, $_mutex->{_w_sock},
      PF_UNIX, SOCK_STREAM, PF_UNSPEC ) or die "socketpair: $!\n";

   binmode $_mutex->{_r_sock};
   binmode $_mutex->{_w_sock};

   my $_old_hndl = select $_mutex->{_r_sock}; $| = 1;
                   select $_mutex->{_w_sock}; $| = 1;

   select $_old_hndl;

   syswrite $_mutex->{_w_sock}, '0';

   return $_mutex;
}

###############################################################################
## ----------------------------------------------------------------------------
## Lock method.
##
###############################################################################

sub lock {

   my ($_mutex) = @_;

   sysread $_mutex->{_r_sock}, my $_b, 1;

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Unlock method.
##
###############################################################################

sub unlock {

   my ($_mutex) = @_;

   syswrite $_mutex->{_w_sock}, '0';

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Synchronize method.
##
###############################################################################

sub synchronize {

   my ($_mutex, $_code) = (shift, shift);

   if (ref $_code eq 'CODE') {
      $_mutex->lock; $_code->(@_); $_mutex->unlock;
   }

   return;
}

1;

__END__

###############################################################################
## ----------------------------------------------------------------------------
## Module usage.
##
###############################################################################

=head1 NAME

MCE::Mutex - Simple semaphore for Many-Core Engine

=head1 VERSION

This document describes MCE::Mutex version 1.600

=head1 SYNOPSIS

   use MCE::Flow max_workers => 4;
   use MCE::Mutex;

   print "## running a\n";
   my $a = MCE::Mutex->new;

   mce_flow sub {
      $a->lock;

      ## access shared resource
      my $wid = MCE->wid; MCE->say($wid); sleep 1;

      $a->unlock;
   };

   print "## running b\n";
   my $b = MCE::Mutex->new;

   mce_flow sub {
      $b->synchronize( sub {

         ## access shared resource
         my ($wid) = @_; MCE->say($wid); sleep 1;

      }, MCE->wid );
   };

=head1 DESCRIPTION

This module implements locking methods that can be used to coordinate access
to shared data from multiple workers spawned as threads or processes.

=back

=head1 API DOCUMENTATION

=over 3

=item ->new ( void )

Creates a new mutex.

=item ->lock ( void )

Attempts to grab the lock and waits if not available.

=item ->unlock ( void )

Releases the lock.

=item ->synchronize ( sub { ... }, @_ )

Obtains a lock, runs the code block, and releases the lock after the block
completes.

=back

=head1 INDEX

L<MCE|MCE>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=head1 LICENSE

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See L<http://dev.perl.org/licenses/> for more information.

=cut

