# BEGIN BPS TAGGED BLOCK {{{
#
# COPYRIGHT:
#
# This software is Copyright (c) 1996-2026 Best Practical Solutions, LLC
#                                          <sales@bestpractical.com>
#
# (Except where explicitly superseded by other copyright notices)
#
#
# LICENSE:
#
# This work is made available to you under the terms of Version 2 of
# the GNU General Public License. A copy of that license should have
# been provided with this software, but in any event can be snarfed
# from www.gnu.org.
#
# This work is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
# 02110-1301 or visit their web page on the internet at
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.html.
#
#
# CONTRIBUTION SUBMISSION POLICY:
#
# (The following paragraph is not intended to limit the rights granted
# to you to modify and distribute this software under the terms of
# the GNU General Public License and is only of importance to you if
# you choose to contribute your changes and enhancements to the
# community by submitting them to Best Practical Solutions, LLC.)
#
# By intentionally submitting any modifications, corrections or
# derivatives to this work, or any other work intended for use with
# Request Tracker, to Best Practical Solutions, LLC, you confirm that
# you are the copyright holder for those contributions and you grant
# Best Practical Solutions,  LLC a nonexclusive, worldwide, irrevocable,
# royalty-free, perpetual, license to use, copy, create derivative
# works based on those contributions, and sublicense and distribute
# those contributions and any derivatives thereof.
#
# END BPS TAGGED BLOCK }}}

use strict;
use warnings;

package RT::Record::Role::Rights;
use Role::Basic;
use Scalar::Util qw(blessed);

=head1 NAME

RT::Record::Role::Rights - Common methods for records which can provide rights

=head1 DESCRIPTION

=head1 REQUIRES

=head2 L<RT::Record::Role>

=cut

with 'RT::Record::Role';

# C<class;:;lifecycle type;:;lifecycle> => hashref of rights. Cleared whenever a
# right is registered and whenever the lifecycle cache is rebuilt.
our %AVAILABLE_RIGHTS_CACHE;

=head1 PROVIDES

=cut

=head2 AddRight C<CATEGORY>, C<RIGHT>, C<DESCRIPTION>

Adds the given rights to the list of possible rights.  This method
should be called during server startup, not at runtime.

=cut

sub AddRight {
    my $class = shift;
    $class = ref($class) || $class;
    my ($category, $name, $description) = @_;

    require RT::ACE;
    if (exists $RT::ACE::RIGHTS{$class}{lc $name}) {
        warn "Duplicate right '$name' found";
        return;
    }

    $RT::ACE::RIGHTS{$class}{lc $name} = {
        Name        => $name,
        Category    => $category,
        Description => $description,
    };

    undef $RT::ACE::RIGHTS_BY_LC;
    %AVAILABLE_RIGHTS_CACHE = ();
}

=head2 AvailableRights

Returns a hashref of available rights for this object. The keys are the
right names and the values are a description of what the rights do.

=cut

sub AvailableRights {
    my $self = shift;
    my $class = ref($self) || $self;

    # Fetch the lifecycle once: RT::Queue::Lifecycle goes through _Value, which
    # runs a SeeQueue check. Calling it twice would double that work, and the
    # lifecycle name is part of the cache key because a user who cannot see the
    # queue gets undef here and therefore a different (smaller) right set.
    my ( $lifecycle_type, $lifecycle );
    if ( blessed($self) && $self->DOES('RT::Record::Role::Lifecycle') ) {
        $lifecycle_type = $self->LifecycleType;
        $lifecycle      = $self->Lifecycle;
    }

    my $cache_key = $class;
    if ( defined $lifecycle_type ) {
        $cache_key .= ';:;' . $lifecycle_type . ';:;' . ( $lifecycle // '' );
    }

    if ( $AVAILABLE_RIGHTS_CACHE{$cache_key} ) {
        return $AVAILABLE_RIGHTS_CACHE{$cache_key};
    }

    my %rights;
    if ( defined $lifecycle_type ) {
        %rights = RT::Lifecycle->RightsDescription( $lifecycle_type, $lifecycle );
    }

    $rights{ $_->{Name} } = $_->{Description}
        for grep { $_->{Category} ne 'Status' } values %{ $RT::ACE::RIGHTS{$class} || {} };

    return $AVAILABLE_RIGHTS_CACHE{$cache_key} = \%rights;
}

=head2 RightCategories

Returns a hashref where the keys are rights for this type of object and the
values are the category (General, Staff, Admin) the right falls into.

=cut

sub RightCategories {
    my $self = shift;
    my $class = ref($self) || $self;

    my %rights;
    $rights{$_->{Name}} = $_->{Category}
        for values %{ $RT::ACE::RIGHTS{$class} || {} };
    return \%rights;
}

require RT::Base;
RT::Base->_ImportOverlays();

1;
