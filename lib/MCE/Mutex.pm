###############################################################################
## ----------------------------------------------------------------------------
## MCE::Mutex - Simple semaphore for Many-Core Engine.
##
###############################################################################

package MCE::Mutex;

use strict;
use warnings;

no warnings 'threads';
no warnings 'recursion';
no warnings 'uninitialized';

use MCE::Util qw( $LF );
use bytes;

our $VERSION = '1.606';

sub DESTROY {

   my ($_mutex, $_arg) = @_;
   my $_id = $INC{'threads.pm'} ? $$ .'.'. threads->tid() : $$;

   $_mutex->unlock() if ($_mutex->{ $_id });

   if (!defined $_arg || $_arg ne 'shutdown') {
      return if (defined $MCE::VERSION && !defined $MCE::MCE->{_wid});
      return if (defined $MCE::MCE && $MCE::MCE->{_wid});
   }

   MCE::Util::_destroy_sockets($_mutex, qw(_w_sock _r_sock));

   return;
}

###############################################################################
## ----------------------------------------------------------------------------
## Public methods.
##
###############################################################################

sub new {

   my ($_class, %_argv) = @_;   @_ = ();
   my $_mutex = {}; bless($_mutex, ref($_class) || $_class);

   MCE::Util::_make_socket_pair($_mutex, qw(_w_sock _r_sock));

   syswrite($_mutex->{_w_sock}, '0');

   return $_mutex;
}

sub lock {

   my $_mutex = shift;
   my $_id    = $INC{'threads.pm'} ? $$ .'.'. threads->tid() : $$;

   unless ($_mutex->{ $_id }) {
      sysread($_mutex->{_r_sock}, my $_b, 1);
      $_mutex->{ $_id } = 1;
   }

   return;
}

sub unlock {

   my $_mutex = shift;
   my $_id    = $INC{'threads.pm'} ? $$ .'.'. threads->tid() : $$;

   if ($_mutex->{ $_id }) {
      syswrite($_mutex->{_w_sock}, '0');
      $_mutex->{ $_id } = 0;
   }

   return;
}

sub synchronize {

   my ($_mutex, $_code) = (shift, shift);

   if (ref $_code eq 'CODE') {
      if (defined wantarray) {
         $_mutex->lock();   my @_a = $_code->(@_);
         $_mutex->unlock();

         return wantarray ? @_a : $_a[0];
      }
      else {
         $_mutex->lock();   $_code->(@_);
         $_mutex->unlock();
      }
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

This document describes MCE::Mutex version 1.606

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
to shared data from multiple workers spawned as processes or threads.

The inspiration for this module came from reading Mutex for Ruby.

=head1 API DOCUMENTATION

=head2 MCE::Mutex->new ( void )

Creates a new mutex.

=head2 $m->lock ( void )

Attempts to grab the lock and waits if not available. Multiple calls to
mutex->lock by the same process or thread is safe. The mutex will remain
locked until mutex->unlock is called.

=head2 $m->unlock ( void )

Releases the lock. A held lock by an exiting process or thread is released
automatically.

=head2 $m->synchronize ( sub { ... }, @_ )

Obtains a lock, runs the code block, and releases the lock after the block
completes. Optionally, the method is wantarray aware.

   my $value = $m->synchronize( sub {

      ## access shared resource

      'value';
   });

=head1 INDEX

L<MCE|MCE>

=head1 AUTHOR

Mario E. Roy, S<E<lt>marioeroy AT gmail DOT comE<gt>>

=cut

