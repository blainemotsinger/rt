use strict;
use warnings;
use RT::Test tests => undef, config => q{
Set($DefaultQueue, 1); # General
};

my $test_queue = RT::Test->load_or_create_queue( Name => 'Test' );
my $config     = RT::Configuration->new( RT->SystemUser );
my ( $ret, $msg ) = $config->Create( Name => 'DefaultQueue', Content => $test_queue->Id );
ok( $ret, 'Created DefaultQueue config' );
is( $msg, q{DefaultQueue changed from "General" to "Test"}, 'Created message' );

done_testing;
