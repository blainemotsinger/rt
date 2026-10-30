use strict;
use warnings;

# DASH-8: Dashboard::Dashboards and Dashboard::SavedSearches used to ignore the
# return value of Load/LoadById, so a portlet whose dashboard or saved search no
# longer exists came back as an empty object. PossibleHiddenSearches() then
# reported it as a hidden search, and anything rendering the returned list got a
# blank entry. Failed loads must be dropped.

use RT::Test tests => undef;

my $user = RT::Test->load_or_create_user(
    Name         => 'portletuser',
    Password     => 'password',
    EmailAddress => 'portletuser@example.com',
    Privileged   => 1,
);
ok $user && $user->id, 'created user';

# Content is only readable for a user who can see the dashboard, so the loader
# below needs the right even though it loads by id.
$user->PrincipalObj->GrantRight( Right => $_, Object => RT->System )
    for qw/SeeOwnDashboard AdminOwnDashboard/;

my $current = RT::CurrentUser->new($user);

my $search = RT::SavedSearch->new( RT->SystemUser );
my ( $search_id, $search_msg ) = $search->Create(
    Name        => 'a loadable search',
    Type        => 'Ticket',
    PrincipalId => $user->Id,
    Content     => '',
);
ok $search_id, "created saved search: $search_msg";

my $sub = RT::Dashboard->new( RT->SystemUser );
my ( $sub_id, $sub_msg ) = $sub->Create(
    Name        => 'sub dashboard',
    PrincipalId => $user->Id,
);
ok $sub_id, "created sub dashboard: $sub_msg";

my $parent = RT::Dashboard->new( RT->SystemUser );
my ( $parent_id, $parent_msg ) = $parent->Create(
    Name        => 'parent dashboard',
    PrincipalId => $user->Id,
    Content     => {
        Elements => [
            {
                Layout   => 'col-12',
                Elements => [
                    [
                        { portlet_type => 'search',    id => $search_id },
                        { portlet_type => 'search',    id => 999_999 },
                        { portlet_type => 'dashboard', id => $sub_id },
                        { portlet_type => 'dashboard', id => 888_888 },
                    ]
                ],
            }
        ],
    },
);
ok $parent_id, "created parent dashboard: $parent_msg";

my $loader = RT::Dashboard->new($current);
my ( $loaded, $load_msg ) = $loader->LoadById($parent_id);
ok $loaded, "loaded the parent dashboard: $load_msg";

my @searches = $loader->SavedSearches;
is scalar @searches, 1, 'the dangling saved search portlet is skipped';
is $searches[0]->id, $search_id, 'and the loadable one is returned';

my @dashboards = $loader->Dashboards;
is scalar @dashboards, 1, 'the loadable sub-dashboard is still returned';
is $dashboards[0]->id, $sub_id, 'and it is the right one';

# A portal list that loads cleanly is unaffected.
my $clean = RT::Dashboard->new( RT->SystemUser );
my ( $clean_id, $clean_msg ) = $clean->Create(
    Name        => 'clean dashboard',
    PrincipalId => $user->Id,
    Content     => {
        Elements => [
            {
                Layout   => 'col-12',
                Elements => [ [ { portlet_type => 'dashboard', id => $sub_id } ] ],
            }
        ],
    },
);
ok $clean_id, "created clean dashboard: $clean_msg";

my $clean_loader = RT::Dashboard->new($current);
$clean_loader->LoadById($clean_id);
is scalar( $clean_loader->Dashboards ), 1,
    'a dashboard with only loadable portlets still returns them';

# PossibleHiddenSearches is the caller that cared: a dangling portlet must not be
# reported as a search that some viewers cannot see.
is $loader->PossibleHiddenSearches, 0,
    'a deleted portlet is not reported as a hidden search';

done_testing();
