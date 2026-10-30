use strict;
use warnings;

use Scalar::Util qw(refaddr);

use RT::Test tests => undef;

my $user = RT::Test->load_or_create_user(
    Name         => 'shorteneruser',
    Password     => 'password',
    EmailAddress => 'shortener@example.com',
);
ok $user && $user->id, 'loaded or created user';

my $current_user = RT::CurrentUser->new($user);

my $shortener = RT::Shortener->new($current_user);
my ( $id, $msg ) = $shortener->Create(
    Content => 'Query=id<10&Rows=50&Format=__id__',
);
ok $id, "created shortener: $msg";
ok $shortener->Code, 'shortener has a code';

# ExpandShortenerCode reaches for the web request object; give it the smallest
# thing with the one method it calls outside of the Shredder branch.
{
    package Fake::WebRequest;
    sub path_info { '/Search/Results.html' }
}

note "decoded content is computed once per shortener object";
{
    my $first  = $shortener->DecodedContent;
    my $second = $shortener->DecodedContent;

    is $first->{Query}, 'id<10', 'content decoded';
    is $first->{Rows},  50,      'repeatable field decoded';
    is refaddr($first), refaddr($second),
        'two reads returned the same structure';
}

note "an explicit content argument is decoded without touching the memo";
{
    my $other = $shortener->DecodedContent('Rows=25&Order=ASC');
    is $other->{Rows},  25,  'the argument was decoded';
    is $other->{Order}, 'ASC', 'and so was its other field';

    is $shortener->DecodedContent->{Rows}, 50,
        'the object memo still holds the row content';
}

note "expanding a code still works and does not record an access by default";
{
    local $HTML::Mason::Commands::session{CurrentUser} = $current_user;
    local $HTML::Mason::Commands::r = bless {}, 'Fake::WebRequest';

    $shortener->__Set( Field => 'LastAccessed',   Value => '2020-01-01 00:00:00' );
    $shortener->__Set( Field => 'LastAccessedBy', Value => 1 );

    my %args = ( sc => $shortener->Code );
    RT::Interface::Web::ExpandShortenerCode( \%args, SetLastAccessed => 0 );

    is $args{Query}, 'id<10', 'the code was expanded into the args';
    is $args{Rows},  50,      'all stored fields were expanded';

    my $reloaded = RT::Shortener->new($current_user);
    $reloaded->Load( $shortener->id );
    is $reloaded->LastAccessed, '2020-01-01 00:00:00',
        'an internal load left LastAccessed alone';
    is $reloaded->LastAccessedBy, 1,
        'an internal load left LastAccessedBy alone';
}

note "a real navigation records the access";
{
    local $HTML::Mason::Commands::session{CurrentUser} = $current_user;
    local $HTML::Mason::Commands::r = bless {}, 'Fake::WebRequest';

    my %args = ( sc => $shortener->Code );
    RT::Interface::Web::ExpandShortenerCode( \%args );

    my $reloaded = RT::Shortener->new($current_user);
    $reloaded->Load( $shortener->id );
    isnt $reloaded->LastAccessed, '2020-01-01 00:00:00',
        'the default path updated LastAccessed';
    is $reloaded->LastAccessedBy, $current_user->id,
        'the default path updated LastAccessedBy';
}

done_testing();
