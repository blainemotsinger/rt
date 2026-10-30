use strict;
use warnings;

# ACL-7: HasMemberRecursively used to load CachedGroupMembers without a
# Disabled filter, so a disabled group still reported its members as members.
# It also ran one query per call. The cached closure is now built with
# Disabled = 0 and answered from memory until a membership write clears it.

use RT::Test tests => undef;

my $user = RT::Test->load_or_create_user(
    Name         => 'recursiveuser',
    Password     => 'password',
    EmailAddress => 'recursive@example.com',
    Privileged   => 1,
);
ok $user && $user->id, 'created user';

sub make_group {
    my $name = shift;
    my $group = RT::Group->new( RT->SystemUser );
    my ( $id, $msg ) = $group->CreateUserDefinedGroup( Name => $name );
    ok $id, "created group $name: $msg";
    return $group;
}

my $outer = make_group('recursive-outer');
my $middle = make_group('recursive-middle');
my $inner = make_group('recursive-inner');

my ( $ok, $msg ) = $middle->AddMember( $inner->PrincipalId );
ok $ok, "nested inner in middle: $msg";

( $ok, $msg ) = $outer->AddMember( $middle->PrincipalId );
ok $ok, "nested middle in outer: $msg";

( $ok, $msg ) = $inner->AddMember( $user->PrincipalId );
ok $ok, "added user to inner: $msg";

note 'a user three groups deep is found at every level';
ok $outer->HasMemberRecursively( $user->id ), 'outer sees the user';
ok $middle->HasMemberRecursively( $user->id ), 'middle sees the user';
ok $inner->HasMemberRecursively( $user->id ), 'inner sees the user';

note 'disabling the group in the middle removes the recursive membership';
( $ok, $msg ) = $middle->SetDisabled(1);
ok $ok, "disabled the middle group: $msg";

ok !$outer->HasMemberRecursively( $user->id ),
    'outer no longer sees the user through a disabled group';
ok $inner->HasMemberRecursively( $user->id ),
    'the direct membership still counts';

( $ok, $msg ) = $middle->SetDisabled(0);
ok $ok, "re-enabled the middle group: $msg";
ok $outer->HasMemberRecursively( $user->id ), 'outer sees the user again';

note 'adding and deleting a membership invalidates the cache';
{
    my $group = make_group('recursive-direct');
    ok !$group->HasMemberRecursively( $user->id ), 'not a member yet';

    my ( $added, $add_msg ) = $group->AddMember( $user->PrincipalId );
    ok $added, "added the user: $add_msg";
    ok $group->HasMemberRecursively( $user->id ), 'membership is visible immediately';

    my ( $deleted, $delete_msg ) = $group->DeleteMember( $user->PrincipalId );
    ok $deleted, "deleted the user: $delete_msg";
    ok !$group->HasMemberRecursively( $user->id ), 'removal is visible immediately';
}

note 'one query answers every group for the same principal';
{
    my $watch = RT->DatabaseHandle;
    DBIx::SearchBuilder::Record::Cachable->FlushCache;

    $watch->LogSQLStatements(1);
    $watch->ClearSQLStatementLog;

    my @groups = $outer;
    for my $n ( 1 .. 10 ) {
        push @groups, make_group("recursive-query-$n");
    }

    # The group creation above is not what we are counting.
    $watch->ClearSQLStatementLog;

    $groups[-1]->AddMember( $user->PrincipalId );
    $watch->ClearSQLStatementLog;

    $_->HasMemberRecursively( $user->id ) for @groups;

    my @log = $watch->SQLStatementLog;
    $watch->LogSQLStatements(0);

    my @cgm = grep { $_->[1] =~ /\bFROM\s+CachedGroupMembers\b/i } @log;
    is scalar @cgm, 1, 'eleven groups resolve with one CachedGroupMembers query';
}

done_testing();
