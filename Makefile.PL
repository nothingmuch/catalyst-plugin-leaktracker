use inc::Module::Install;

my $module = 'Catalyst::Plugin::LeakTracker';

my $dist   = $module;
$dist =~ s/::/-/g;
name($dist);

my @path = split '::', $module;
all_from('lib/'. (join '/',@path). '.pm');

build_requires 'Catalyst::Runtime';
build_requires 'Test::WWW::Mechanize::Catalyst';
build_requires 'Test::More';
build_requires 'ok';

requires 'Catalyst::Plugin::C3';

requires 'Devel::Events';

# these might be separate dists
requires 'Devel::Events::Handler::ObjectTracker';
requires 'Devel::Events::Generator::Objects';

WriteAll();
