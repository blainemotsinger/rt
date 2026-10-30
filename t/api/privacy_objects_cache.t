use strict;
use warnings;

# DASH-5: the menu asks for the dashboards and the saved searches a user can
# load on every page, and each of those built its own "user-defined groups the
# current user is in" query. They now share one request-scoped list, dropped
# by RT::Principal::InvalidateMembershipCache (membership writes and
# end-of-request cleanup).

use RT::Test tests => undef;
use RT::Dashboard;
use RT::SavedSearch;

my $user = RT::Test->load_or_create_user(
    Name         => 'privacyobjects',
    EmailAddress => 'privacyobjects@example.com',
    Password     => 'password',
);
ok $user && $user->id, 'user';

my @groups;
for my $i ( 1 .. 3 ) {
    my $group = RT::Group->new( RT->SystemUser );
    my ( $gid, $gmsg ) = $group->CreateUserDefinedGroup( Name => "privacy-objects-$i" );
    ok $gid, "created group: $gmsg";
    $group->AddMember( $user->PrincipalId );
    push @groups, $group;
}

my $current_user = RT::CurrentUser->new($user);
my $handle       = RT->DatabaseHandle;

sub capture_sql {
    my $code = shift;

    $handle->ClearSQLStatementLog;
    $handle->LogSQLStatements(1);
    my @result = $code->();
    my @log    = $handle->SQLStatementLog;
    $handle->LogSQLStatements(0);

    return ( \@log, \@result );
}

sub group_ids {
    my $objects = shift;
    return [ sort map { $_->isa('RT::Group') ? $_->id : () } @$objects ];
}

note 'the second privacy-object list is answered from the cache';
{
    # Warm the record and ACL caches, then clear only the membership caches:
    # what is left is one group query per list build.
    $current_user->UserObj;
    RT::SavedSearch->new($current_user)->_PrivacyObjects;
    RT::Principal->InvalidateMembershipCache;

    my ( $first_log, $first_objects ) = capture_sql(sub {
        RT::SavedSearch->new($current_user)->_PrivacyObjects;
    });
    cmp_ok scalar @$first_log, '>', 0, 'the first build runs the group query';

    my ( $second_log, $second_objects ) = capture_sql(sub {
        RT::Dashboard->new($current_user)->_PrivacyObjects;
    });
    is scalar @$second_log, 0, 'the second build runs no queries at all';

    is_deeply group_ids($second_objects), group_ids($first_objects),
        'both builders see the same groups';
    is_deeply group_ids($first_objects), [ sort map { $_->id } @groups ],
        'the list is the user-defined groups the user is in';
}

note 'an empty group list is cached too';
{
    my $loner = RT::Test->load_or_create_user(
        Name         => 'privacyobjects-loner',
        EmailAddress => 'privacyobjects-loner@example.com',
        Password     => 'password',
    );
    my $loner_cu = RT::CurrentUser->new($loner);
    $loner_cu->UserObj;
    RT::Principal->InvalidateMembershipCache;

    my ( $first_log ) = capture_sql(sub {
        RT::Dashboard->new($loner_cu)->_PrivacyObjects;
    });
    cmp_ok scalar @$first_log, '>', 0, 'the first build runs the group query';

    my ( $second_log ) = capture_sql(sub {
        RT::SavedSearch->new($loner_cu)->_PrivacyObjects;
    });
    is scalar @$second_log, 0, 'the empty list is cached, not rebuilt';
}

note 'a membership write drops the cached list';
{
    my $before = group_ids( [
        RT::Dashboard->new($current_user)->_PrivacyObjects
    ] );

    my $group = RT::Group->new( RT->SystemUser );
    my ( $gid, $gmsg ) = $group->CreateUserDefinedGroup( Name => 'privacy-objects-new' );
    ok $gid, "created group: $gmsg";
    $group->AddMember( $user->PrincipalId );

    my $after = group_ids( [
        RT::Dashboard->new($current_user)->_PrivacyObjects
    ] );

    ok !grep( { $_ == $gid } @$before ), 'the new group was not in the old list';
    ok grep( { $_ == $gid } @$after ), 'the membership write invalidated the list';
}

done_testing();
