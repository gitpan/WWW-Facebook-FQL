package WWW::Facebook::FQL;

=head1 NAME

WWW::Facebook::FQL - Simple interface to Facebook's FQL query language

=head1 SYNOPSIS

  use WWW::Facebook::FQL;

  ## Log in
  my $fb = new WWW::Facebook::FQL email => $my_email, pass => $my_pass;
  ## Get your own name and pic back:
  $fb->query("SELECT name, pic FROM user WHERE uid=$fb->{uid}");
  ## Get your friends' names and pics:
  $fb->query("SELECT name, pic FROM user WHERE uid IN "
           . "(SELECT uid2 FROM friend WHERE uid1 = $fb->{uid})");

=head1 DESCRIPTION

WWW::Facebook::FQL aims to make it easy to perform Facebook Query
Language (FQL) queries from a Perl program, rather than to reflect the
whole PHP Facebook API.  For those comfortable with SQL, this may be a
more comfortable interface.  Results are currently returned in the raw
JSON or XML format, but more palatable options may be available in the
future.

=cut

use URI::Escape;
use WWW::Mechanize;
use Digest::MD5 qw(md5_hex);
use strict;

use vars qw($VERSION);
$VERSION = '0.01';

use vars qw($rest %FIELDS %IXFIELDS);
$rest = 'http://api.facebook.com/restserver.php';

sub dprint
{
    my $self = shift;
    my $lev = shift;
    if ($lev <= $self->{verbose}) {
        print STDERR @_;
    }
}

sub _sig
{
    my $secret = shift;
    md5_hex uri_unescape(join '', sort(@_), $secret);
}

sub get
{
    my $self = shift;
    ($self->{mech} ||= new WWW::Mechanize)->get(@_);
}

sub _request
{
    my ($self, $method, %o) = @_;
    $o{format} ||= $self->{format};
    $method = "facebook.$method";
    my @params = ("api_key=$self->{key}",
                  "method=$method",
                  'v=1.0',
                  $self->{session_key} ? ('session_key='.$self->{session_key},
                                      'call_id='.(++$self->{callid})) : (),
                  map { "$_=".uri_escape($o{$_}) } keys %o);
    my $sig = _sig($self->{secret}, @params);
    my $url = "$rest?".join '&', @params, "sig=$sig\n";
    $self->dprint(1, $url);
    my $resp = $self->get("$rest?".join '&', @params, "sig=$sig");
    if (!$resp->is_success) {
        $self->dprint(0, "Request '$url' failed.\n");
    }
    $self->dprint(2, "RESPONSE ", '=' x 50, "\n", $resp->decoded_content,
                  "\n", '=' x 70, "\n");
    $resp;
}

## XXX - This doesn't use _request because the initial
## auth.createToken is quite different.
sub _get_auth_token
{
    my ($self) = @_;
    $self->{auth_token} = $self->{secret};
    my $resp = $self->_request('auth.createToken', format => 'JSON');
    $self->{auth_token} = eval $resp->decoded_content if $resp->is_success;
}

sub _get_session
{
    my $self = shift;
    my $resp;
    {
        local $rest = $rest;
        $rest =~ s/^http/https/;
        $resp = $self->_request('auth.getSession', format => 'XML',
                                auth_token => $self->{auth_token});
    }
    local $_ = $resp->decoded_content;
    if (!$resp->is_success) {
        $self->dprint(0, "Can't get session.\n");
    } else {
	$self->{old_secret} = $self->{secret};        
        for my $word (qw(uid session_key expires secret)) {
            ($self->{$word}) = /<$word>(.*?)<\/$word>/;
        }
        $self->dprint(1, "Session expires at ",
                      scalar localtime($self->{expires}), "\n");
    }
}

=head2 C<$fb = new WWW::Facebook::FQL key =E<gt> value, ...>

Create a new Facebook FQL session for user $EMAIL with password $PASS.
Keyword arguments include

=over 4

=item email -- the email address of your Facebook account.

=item pass -- your password.

=item verbose -- A number controlling debugging information.

=item key -- The public part of your API key.

You need to sign up for this on Facebook by joining the "Developers"
group and requesting an API key.

=item secret -- The private part of your API key.

=item format -- Data return format, either 'XML' (the default) or 'JSON'.

=back

WWW::Facebook::FQL reads default values from the file $HOME/.fqlrc if
it exists.  It should contain the innards of an argument list, and
will be evaluated like C<@args = eval "($FILE_CONTENTS)">.  The
constructor will I<not> prompt for any parameters; it is the calling
program's responsibility to get sensitive information from the user in
an appropriate way.

=cut

sub new
{
    my $class = shift;
    my @def = (format => 'XML', verbose => 0);
    if (-f "$ENV{HOME}/.fqlrc") {
        local $/;
        if (open IN, "$ENV{HOME}/.fqlrc") {
            my @tmp = eval '('.<IN>.')';
            push @def, @tmp unless $@;
            close IN;
        }
    }
    my %o = (@def, @_);
    my $self = bless \%o, $class;
    $self->_get_auth_token;
    my $mech = $self->{mech};
    $mech->get("http://www.facebook.com/login.php?api_key=$self->{key}&v=1.0&auth_token=$self->{auth_token}&hide_checkbox=1&skipcookie=1");
    ## XXX check response
    my $resp = $mech->submit_form(with_fields => {
        email => $self->{email},
        pass => $self->{pass}
    });
    if (!$resp->is_success) {
        $self->dprint(0, "login failed: \n", $resp->decoded_content, "\n",
                      '='x 70, "\n");
        return undef;
    }
    $self->dprint(2, "Logged in as $self->{email}\n");
    ## XXX check response
    if ($mech->content =~ /Terms of Service/) {
        $mech->submit_form(form_name => 'confirm_grant_form');
        $self->dprint(2, "Agreed to terms of service.");
    }
    ## Get session key
    $self->_get_session;
    $self;
}

=head2 C<$result = $fb->query($QUERY)

Perform FQL query $QUERY, returning the result in format $FORMAT
(either XML or JSON, JSON by default).  FQL is a lot like SQL, but
with its own set of weird and privacy-related restrictions; for a
description, see
L<http://developers.facebook.com/documentation.php?v=1.0&doc=fql>.

=cut

sub query
{
    my ($self, $q) = @_;
    $self->_request('fql.query', query => $q)->decoded_content;
}

BEGIN {
%FIELDS = (
    user => [qw(uid* first_name last_name name* pic_small pic_big
    pic_square pic affiliations profile_update_time timezone religion
    birthday sex hometown_location meeting_sex meeting_for
    relationship_status significant_other_id political
    current_location activities interests is_app_user music tv movies
    books quotes about_me hs_info education_history work_history
    notes_count wall_count status has_added_app)],

    friend => [qw(uid1* uid2*)],

    group => [qw(gid* name nid pic_small pic_big pic description
    group_type group_subtype recent_news creator update_time office
    website venue)],

    group_member => [qw(uid* gid* positions)],

    event => [qw(eid* name tagline nid pic_small pic_big pic host
    description event_type event_subtype start_time end_time creator
    update_time location venue)],

    event_member => [qw(uid* eid* rsvp_status)],

    photo => [qw(pid* aid* owner src_small src_big src link caption
    created)],

    album => [qw(aid* cover_pid* owner* name created modified
    description location size)],

    photo_tag => [qw(pid* subject* xcoord ycoord)],
);

for (keys %FIELDS) {
    $IXFIELDS{$_} = [grep /\*$/, @{$FIELDS{$_}}];
    s/\*$// for @{$FIELDS{$_}};
}

} ## END BEGIN

1;
__END__

=head2 C<%FIELDS> -- table_name -E<gt> [fields]

Map table names to available fields.  This is particularly useful
since FQL doesn't allow "SELECT *".

=head2 C<%IXFIELDS> -- table_name -E<gt> [indexed_fields]

Map table names to "indexable" fields, i.e. those fields that can be
part of a WHERE clause.

=head1 SEE ALSO

The canonical (PHP) API Documentation
(L<http://developers.facebook.com/documentation.php>), especially the
FQL document
(L<http://developers.facebook.com/documentation.php?v=1.0&doc=fql>).

L<WWW::Facebook::API> for bindings to the full API.

=head1 BUGS and TODO

Since FQL is so much like SQL, it might be cool to make
DBD::Facebook...

=head1 AUTHOR

Sean O'Rourke, E<lt>seano@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2007 by Sean O'Rourke

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
