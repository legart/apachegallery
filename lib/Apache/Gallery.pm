package Apache::Gallery;

# $Author$ $Rev$
# $Date$

use strict;

use vars qw($VERSION);

$VERSION = "0.4";

use Apache ();
use Apache::Constants qw(:common);
use Apache::Request();

use Image::Info qw(image_info);
use Image::Size qw(imgsize);
use CGI::FastTemplate;
use File::stat;
use POSIX qw(floor);
use URI::Escape;

my $escape_rule = "^A-Za-z0-9\-_.!~*'()\/";

use Inline C => Config => 
				LIBS => '-L/usr/X11R6/lib -lImlib2 -lttf -lm -ldl -lXext -lXext',
				DIRECTORY => Apache->request()->dir_config('InlineDir') ?  Apache->request()->dir_config('InlineDir') : "/tmp/",
				INC => '-I/usr/X11R6/include',
				ENABLE    => 'UNTAINT';

use Inline 'C';
Inline->init;

sub handler {

	my $r = shift or Apache->request();

	$r->header_out("X-Powered-By","apachegallery.dk $VERSION - Hest design!");
	$r->header_out("X-Gallery-Version", '$Rev$ $Date$');

	if ($r->header_only) {
		$r->send_http_header;
		return OK;
	}

	my $apr = Apache::Request->instance($r, DISABLE_UPLOADS => 1, POST_MAX => 1024);

	# dirs we do not serve content from directly
	if ($r->uri =~ m/(^\/icons|\.cache)/i) {
		return DECLINED;
	}

	my $uri = $r->uri;
	$uri =~ s/\/$//;

	my $filename = $r->filename;
	$filename =~ s/\/$//;
	my $topdir   = $filename;

	unless (-f $filename or -d $filename) {
	
		show_error($r, "404!", "No such file or directory: ".$r->uri);
		return OK;
	}

	# unless it is one of the filetypes we server with Apache::Gallery
	if (-f $filename && $filename !~ m/\.(?:jpe?g|png|tiff?|ppm)$/i) {
		return DECLINED;
	}

	if (-d $filename) {

		unless (-d $filename."/.cache") {
			unless (mkdir ($filename."/.cache", 0777)) {
				show_error($r, $!, "Unable to create .cache dir in $filename: $!");
				return OK;
			}
		}

		my $tpl = new CGI::FastTemplate($r->dir_config('GalleryTemplateDir'));

		$tpl->define(
			layout    => 'layout.tpl',
			index     => 'index.tpl',
			directory => 'directory.tpl',
			picture   => 'picture.tpl',
			movie     => 'movie.tpl'
		);

		$tpl->assign(TITLE => "Index of: ".$uri);

		unless (opendir (DIR, $filename)) {
			show_error ($r, $!, "Unable to access $filename: $!");
			return OK;
		}
		
		$tpl->assign(MENU => generate_menu($r));
	
		# Read, sort, and filter files
		my @files = grep { !/^\./ && -f "$filename/$_" } readdir (DIR);
		@files = sort @files;

		my @movies;

		if (@files) {
			# Remove unwanted files and movies from list
			my $counter = 0;
			my @new_files = ();
			foreach my $picture (@files) {

				my $file = $topdir."/".$picture;

				if ($file =~ m/\.(mpe?g|mov|avi|asf)$/i) {
					push (@movies, $picture);
				}

				if ($file =~ m/\.(?:jpe?g|png|tiff?|ppm)$/i) {
					push (@new_files, $picture);
				}

				$counter++;

			}
			@files = @new_files;
		}

		# Read and sort directories
		rewinddir (DIR);
		my @directories = grep { !/^\./ && -d "$filename/$_" } readdir (DIR);
		@directories = sort @directories;
		closedir(DIR);

		# Combine directories and files to one listing
		my @listing;
		push (@listing, @directories);
		push (@listing, @files);
		push (@listing, @movies);
		
		if (@listing) {

			my $filelist;

			foreach my $file (@listing) {

				my $thumbfilename = $topdir."/".$file;

				my $fileurl = $uri."/".$file;

				if (-d $thumbfilename) {
					my $dirtitle = '';
					if (-e $thumbfilename . ".folder") {
						$dirtitle = get_filecontent($thumbfilename . ".folder");
					}

					$tpl->assign(FILEURL => uri_escape($fileurl, $escape_rule), FILE => ($dirtitle ? $dirtitle : $file));
					$tpl->parse(FILES => '.directory');

				}
				elsif (-f $thumbfilename && $thumbfilename =~ m/\.(mpe?g|avi|mov|asf)$/i) {
					my $type = lc($1);
					my $stat = stat($thumbfilename);
					my $size = $stat->size;
					$tpl->assign(FILEURL => uri_escape($fileurl, $escape_rule), 
					             ALT => "Size: $size Bytes", 
					             FILE => $file, 
					             TYPE => $type);

					$tpl->parse(FILES => '.movie');						 

				}
				elsif (-f $thumbfilename) {

					my ($width, $height, $type) = imgsize($thumbfilename);
					next if $type eq 'Data stream is not a known image file format';

					my @filetypes = qw(JPG TIF PNG PPM);

					next unless (grep $type eq $_, @filetypes);
					my ($thumbnailwidth, $thumbnailheight) = get_thumbnailsize($r, $thumbfilename, $width, $height);	
					my $cached = scale_picture($r, $thumbfilename, $thumbnailwidth, $thumbnailheight);

					my $imageinfo = get_imageinfo($thumbfilename, $type, $width, $height);

					$tpl->assign(FILEURL => uri_escape($fileurl, $escape_rule));
					$tpl->assign(FILE    => $file);
					$tpl->assign(DATE    => $imageinfo->{DateTimeOriginal} ? $imageinfo->{DateTimeOriginal} : ''); # should this really be a stat of the file instead of ''?
					$tpl->assign(SRC     => uri_escape($uri."/.cache/$cached", $escape_rule));

					$tpl->parse(FILES => '.picture');

				}
			}
		
		}
		else {
			$tpl->assign(FILES => "Empty dir");
		}

		$tpl->parse("MAIN", ["index", "layout"]);
		my $content = $tpl->fetch("MAIN");

		$r->content_type('text/html');
		$r->send_http_header;

		$r->print(${$content});
		return OK;

	}
	else {
# original size

		if (defined($ENV{QUERY_STRING}) && $ENV{QUERY_STRING} eq 'orig') {
			if ($r->dir_config('GalleryAllowOriginal') ? 1 : 0) {
				$r->filename($filename);
				return DECLINED;
			} else {
				return FORBIDDEN;
			}
		}
	
		# Create cache dir if not existing
		my @tmp = split (/\//, $filename);
		my $picfilename = pop @tmp;
		my $path = (join "/", @tmp)."/";

		unless (-d $path."/.cache") {
			unless (mkdir ($path."/.cache", 0777)) {
				show_error($r, $!, "Unable to create .cache dir in $path: $!");
				return OK;
			}
		}

		my ($orig_width, $orig_height, $type) = imgsize($filename);
		my $width = $orig_width;

		my $imageinfo = get_imageinfo($filename, $type, $orig_width, $orig_height);

		my $original_size=$orig_height;
 		if ($orig_width>$orig_height) {
			$original_size=$orig_width;
 		}

		# Check if the selected width is allowed
		my @sizes = split (/ /, $r->dir_config('GallerySizes') ? $r->dir_config('GallerySizes') : '640 800 1024 1600');
		if ($apr->param('width')) {
			unless ((grep $apr->param('width') == $_, @sizes) or ($apr->param('width') == $original_size)) {
				show_error($r, "Invalid width", $apr->param('width')." is an invalid width.");
				return OK;
			}
			$width = $apr->param('width');
		}
		else {
			$width = $sizes[0];
		}	

		my $scale;
		my $image_width;
		if ($orig_width<$orig_height) {
			$scale = ($orig_height ? $width/$orig_height: 1);
			$image_width=$width*$orig_width/$orig_height;
		}
		else {
			$scale = ($orig_width ? $width/$orig_width : 1);
			$image_width = $width;
		}

		my $height = $orig_height * $scale;

		$image_width = floor($image_width);
		$width       = floor($width);
		$height      = floor($height);

		my $cached = scale_picture($r, $filename, $image_width, $height);
		
		my $tpl = new CGI::FastTemplate($r->dir_config('GalleryTemplateDir'));

		$tpl->define(
			layout      => 'layout.tpl',
			picture     => 'showpicture.tpl',
			navpicture  => 'navpicture.tpl',
			info        => 'info.tpl',
			scale       => 'scale.tpl',
			orig        => 'orig.tpl'
		);

		$tpl->assign(TITLE => "Viewing ".$r->uri()." at $image_width x $height");
		$tpl->assign(RESOLUTION => "$image_width x $height");
		$tpl->assign(MENU => generate_menu($r));
		$tpl->assign(SRC => ".cache/".$cached);
		$tpl->assign(URI => $r->uri());

		unless (opendir(DATADIR, $path)) {
			show_error($r, "Unable to open dir", "Unable to access $path");
			return OK;
		}
		my @pictures = grep { /^[^.].*\.(jpe?g|png|ppm|tiff?)$/i } readdir (DATADIR);
		closedir(DATADIR);
		@pictures = sort @pictures;

		$tpl->assign(TOTAL => scalar @pictures);
		
		for (my $i=0; $i <= $#pictures; $i++) {
			if ($pictures[$i] eq $picfilename) {

				$tpl->assign(NUMBER => $i+1);

				my $prevpicture = $pictures[$i-1];
				my $displayprev = ($i>0 ? 1 : 0);

				if ($r->dir_config("GalleryWrapNavigation")) {
					$prevpicture = $pictures[$i>0 ? $i-1 : $#pictures];
					$displayprev = 1;
				}	
				if ($prevpicture and $displayprev) {
					my ($orig_width, $orig_height, $type) = imgsize($path.$prevpicture);
					my ($thumbnailwidth, $thumbnailheight) = get_thumbnailsize($r, $path.$prevpicture, $orig_width, $orig_height);	
					my $cached = scale_picture($r, $path.$prevpicture, $thumbnailwidth, $thumbnailheight);
					$tpl->assign(URL       => uri_escape($prevpicture, $escape_rule));
					$tpl->assign(FILENAME  => $prevpicture);
					$tpl->assign(WIDTH     => $width);
					$tpl->assign(PICTURE   => uri_escape(".cache/$cached", $escape_rule));
					$tpl->assign(DIRECTION => "Prev");
					$tpl->parse(BACK => "navpicture");
				}
				else {
					$tpl->assign(BACK => "&nbsp");
				}

				my $nextpicture = $pictures[$i+1];
				if ($r->dir_config("GalleryWrapNavigation")) {
					$nextpicture = $pictures[$i == $#pictures ? 0 : $i+1];
				}	

				if ($nextpicture) {
					my ($orig_width, $orig_height, $type) = imgsize($path.$nextpicture);
					my ($thumbnailwidth, $thumbnailheight) = get_thumbnailsize($r, $path.$nextpicture, $orig_width, $orig_height);	
					my $cached = scale_picture($r, $path.$nextpicture, $thumbnailwidth, $thumbnailheight);
					$tpl->assign(URL       => uri_escape($nextpicture, $escape_rule));
					$tpl->assign(FILENAME  => $nextpicture);
					$tpl->assign(WIDTH     => $width);
					$tpl->assign(PICTURE   => uri_escape(".cache/$cached", $escape_rule));
					$tpl->assign(DIRECTION => "Next");
					$tpl->parse(NEXT => "navpicture");
				}
				else {
					$tpl->assign(NEXT => "&nbsp;");
				}
			}
		}

		if (-e $path . '/' . $picfilename . '.comment' && -f $path . '/' . $picfilename . '.comment') {
		    my $comment_ref = get_comment($path . '/' . $picfilename . '.comment');
		    $tpl->assign(COMMENT => $comment_ref->{COMMENT} . '<br>') if $comment_ref->{COMMENT};
		    $tpl->assign(TITLE => $comment_ref->{TITLE}) if $comment_ref->{TITLE};
		} else {
		    $tpl->assign(COMMENT => '');
		}

		my @infos = split /, /, $r->dir_config('GalleryInfo') ? $r->dir_config('GalleryInfo') : 'Picture Taken => DateTimeOriginal, Flash => Flash';
		my $foundinfo = 0;
		foreach (@infos) {
		
			my ($key, $value) = (split " => ")[0,1];
			if (defined($imageinfo->{$value})) {
				my $content = "";
				if (ref($imageinfo->{$value}) eq 'Image::TIFF::Rational') { 
					$content = $imageinfo->{$value}->as_string;
				} 
				elsif (ref($imageinfo->{$value}) eq 'ARRAY') {
					foreach my $array_el (@{$imageinfo->{$value}}) {
						if (ref($array_el) eq 'ARRAY') {
							foreach (@{$array_el}) {
								$content .= $_ . ' ';
							}
						} 
						elsif (ref($array_el) eq 'HASH') {
							$content .= "<br>{ ";
				    	foreach (sort keys %{$array_el}) {
								$content .= "$_ = " . $array_el->{$_} . ' ';
							}
				    	$content .= "} ";
						} 
						else {
							$content .= $array_el;
						}
						$content .= ' ';
					}
				} 
				else {
					my $keyvalue = $imageinfo->{$value};
					if ($key eq 'Flash' && $keyvalue =~ m/\d/) {
						my %flashmodes = (
							"0"  => "No",
							"1"  => "Yes",
							"9"  => "Yes",
							"16" => "No (Compulsory)",
							"24" => "No",
							"25" => "Yes (Auto)",
							"73" => "Yes (Compulsory, Red Eye Reducing)",
							"89" => "Yes (Auto, Red Eye Reducing)"
						);
						$keyvalue = $flashmodes{$keyvalue};
					}
					$content = $keyvalue;
				}
				$tpl->assign(KEY => $key);
				$tpl->assign(VALUE => $content);
				$tpl->parse(INFO => '.info');
				$foundinfo = 1;
			} 
			else {
				print STDERR $value, " not found in picture info\n";
			}
		}

		unless ($foundinfo) {
			$tpl->assign(INFO => "No info found in image");
		}	

		foreach my $size (@sizes) {
			if ($size<=$original_size) {
				$tpl->assign(IMAGEURI => uri_escape($r->uri(), $escape_rule));
				$tpl->assign(SIZE     => $size);
				$tpl->assign(WIDTH    => $size);
				$tpl->parse(SIZES => '.scale');
			}
		}

		if ($r->dir_config('GalleryAllowOriginal')) {
			$tpl->assign(IMAGEURI => uri_escape($r->uri(), $escape_rule));
			$tpl->parse(SIZES => '.orig');
		}

		$tpl->parse("MAIN", ["picture", "layout"]);
		my $content = $tpl->fetch("MAIN");

		$r->content_type('text/html');
		$r->send_http_header;

		$r->print(${$content});
		return OK;

	}

	return OK;
}

sub scale_picture {

	my ($r, $fullpath, $width, $height) = @_;

	my @dirs = split(/\//, $fullpath);
	my $filename = pop(@dirs);

	my ($orig_width, $orig_height, $type) = imgsize($fullpath);

	my $cache = join ("/", @dirs) . "/.cache";

	my ($thumbnailwidth, $thumbnailheight) = split(/x/, ($r->dir_config('GalleryThumbnailSize') ?  $r->dir_config('GalleryThumbnailSize') : "100x75"));

	# Do we want to generate a new file in the cache?
	my $scale = 1;

	my $newfilename;
	if (grep $type eq $_, qw(PPM TIF)) {
		$newfilename = $width."x".$height."-".$filename;
		# needs to be configurable
		$newfilename =~ s/\.(\w+)$/-$1\.jpg/;
	} else {
		$newfilename = $width."x".$height."-".$filename;
	}
	
	if (-f $cache."/".$newfilename) {	
		$scale = 0;

		# Check to see if the image has changed
		my $filestat = stat($fullpath);
		my $cachestat = stat($cache."/".$newfilename);
		if ($filestat->mtime > $cachestat->mtime) {
			$scale = 1;
		}	

		# Check to see if the .rotate file has been added og changed
		if (-f $fullpath . ".rotate") {
			my $rotatestat = stat($fullpath . ".rotate");
			if ($rotatestat->mtime > $cachestat->mtime) {
				$scale = 1;
			}	
		}		
		# Check to see if the copyrightimage has been added or changed
		if ($r->dir_config('GalleryCopyrightImage') && -f $r->dir_config('GalleryCopyrightImage')) {
			unless ($width == $thumbnailwidth or $width == $thumbnailheight) {
				my $copyrightstat = stat($r->dir_config('GalleryCopyrightImage'));
				if ($copyrightstat->mtime > $cachestat->mtime) {
					$scale = 1;
				}	
			}
		}	

	}	

	if ($scale) {

		my $newpath = $cache."/".$newfilename;

		my $rotate = 0;

		if (-f $fullpath . ".rotate") {
		    $rotate = readfile_getnum($fullpath . ".rotate");
		}

		if ($width == $thumbnailwidth or $width == $thumbnailheight) {
		    resizepicture($fullpath, $newpath, $width, $height, $rotate, '');
		} else {
		    resizepicture($fullpath, $newpath, $width, $height, $rotate, ($r->dir_config('GalleryCopyrightImage') ? $r->dir_config('GalleryCopyrightImage') : ''));
		}
	}

	return $newfilename;

}

sub get_thumbnailsize {
	my ($r, $filename, $orig_width, $orig_height) = @_;

	my ($thumbnailwidth, $thumbnailheight) = split(/x/, ($r->dir_config('GalleryThumbnailSize') ?  $r->dir_config('GalleryThumbnailSize') : "100x75"));

	my $width = $thumbnailwidth;
	if ($orig_width < $orig_height) {
		# rotated image
		$width = $thumbnailheight;
	}
	my $scale = ($orig_width ? $width/$orig_width : 1);
	my $height = $orig_height * $scale;

	$height = floor($height);
	$width  = floor($width);

	return ($width, $height);
}

sub get_imageinfo {
	my ($file, $type, $width, $height) = @_;
	my $imageinfo;
	if ($type eq 'Data stream is not a known image file format') {
		# should never be reached, this is supposed to be handled outside of here
		Apache->request->log_error("Something was fishy with the type of the file $file\n");
	} elsif (grep $type eq $_, qw(PPM TIF PNG)) {
		# These files do not natively have EXIF info embedded in the file
		my $tmpfilename = $file;
		# We have a problem with Windows based file extensions here as they are often .THM
		$tmpfilename =~ s/\.(\w+)$/.thm/;
		if (-e $tmpfilename && -f $tmpfilename && -r $tmpfilename) {
			$imageinfo = image_info($tmpfilename);
		} else {
			$imageinfo = {};
		}
		$imageinfo->{width} = $width;
		$imageinfo->{height} = $height;
	} elsif (grep $type eq $_, qw(JPG)) {
		# Only for files that natively keep the EXIF info in the same file
		$imageinfo = image_info($file);
		# What if this picture doesn't have EXIF info in it?
		if (defined($imageinfo->{error}) && $imageinfo->{error} eq 'Unrecognized file format') {
		    $imageinfo = {};
		    $imageinfo->{width} = $width;
		    $imageinfo->{height} = $height;
		}
	} else {
		$imageinfo = {};
		$imageinfo->{width} = $width;
		$imageinfo->{height} = $height;
	}
	return $imageinfo;
}

sub readfile_getnum {
	my $filename = shift;
	open(FH, "<$filename") or return 0;
	my $temp = <FH>;
	chomp($temp);
	close(FH);
	unless ($temp =~ /^\d$/) {
		return 0;
	}
	unless ($temp == 1 || $temp == 2 || $temp == 3) {
		return 0;
	}
	return $temp;
}

sub get_filecontent {
	my $file = shift;
	open(FH, $file) or return undef;
	my $content = '';
	{
	local $/;
	$content = <FH>;
	}
	close(FH);
	return $content;
}

sub get_comment {
	my $filename = shift;
	my $comment_ref = {};
 	$comment_ref->{TITLE} = undef;
	$comment_ref->{COMMENT} = '';

	my $content = '';
	open(FH, $filename) or return $comment_ref;
	my $title = <FH>;
	if ($title =~ /^TITLE: (.*)$/) {
		$comment_ref->{TITLE} = $1;
	} 
	else {
		$comment_ref->{COMMENT} = $title;
	}
	{
		local $/;
		$comment_ref->{COMMENT} .= <FH>;
	}
	close(FH);

	return $comment_ref;
}

sub show_error {

	my ($r, $errortitle, $error) = @_;

	my $tpl = new CGI::FastTemplate($r->dir_config('GalleryTemplateDir'));

	$tpl->define(
		layout => 'layout.tpl',
		error  => 'error.tpl'
	);

	$tpl->assign(TITLE      => "Error! $errortitle");
	$tpl->assign(ERRORTITLE => "Error! $errortitle");
	$tpl->assign(ERROR      => $error);

	$tpl->parse("MAIN", ["error", "layout"]);

	my $content = $tpl->fetch("MAIN");

	$r->content_type('text/html');
	$r->send_http_header;

	$r->print(${$content});

	return OK;
}

sub generate_menu {

	my $r = shift;

	my $subr = $r->lookup_uri($r->uri);
	my $filename = $subr->filename;

	my @links = split (/\//, $r->uri);

	my $picturename;
	if (-f $filename) {
		$picturename = pop(@links);	
	}

	if ($r->uri eq '/') {
		return qq{ <a href="/">root:</a> };
	}

	my $menu;
	my $menuurl;
	foreach my $link (@links) {

		$menuurl .= $link."/";
		my $linktext = $link;
		unless ($link) {
			$linktext = "root: ";
		}

		$menu .= "<a href=\"".uri_escape($menuurl, $escape_rule)."\">$linktext</a> / ";

	}

	if (-f $filename) {
		$menu .= $picturename;
	}

	return $menu;
}

1;
__DATA__
__C__

#include <X11/Xlib.h>
#include <Imlib2.h>
#include <stdio.h>
#include <string.h>

int resizepicture(char* infile, char* outfile, int x, int y, int rotate, char* copyrightfile) {

	Imlib_Image image;
	Imlib_Image buffer;
	Imlib_Image logo;
	int logo_x, logo_y;
	int old_x;
	int old_y;

	image = imlib_load_image(infile);

	imlib_context_set_image(image);
	imlib_context_set_blend(1);
	imlib_context_set_anti_alias(1);
	
	old_x = imlib_image_get_width();
	old_y = imlib_image_get_height();

	buffer = imlib_create_image(x,y);
	imlib_context_set_image(buffer);
	
	imlib_blend_image_onto_image(image, 0, 0, 0, old_x, old_y, 0, 0, x, y);

	imlib_context_set_image(buffer);
	
	if (rotate != 0) {
	    imlib_image_orientate(rotate);
	}
	if (strcmp(copyrightfile, "") != 0) {
	    logo = imlib_load_image(copyrightfile);

	    imlib_context_set_image(buffer);

	    x = imlib_image_get_width();
	    y = imlib_image_get_height();
	    
	    imlib_context_set_image(logo);
	    
	    logo_x = imlib_image_get_width();
	    logo_y = imlib_image_get_height();

	    imlib_context_set_image(buffer);
	    imlib_blend_image_onto_image(logo, 0, 0, 0, logo_x, logo_y, x-logo_x, y-logo_y, logo_x, logo_y);

	    imlib_context_set_image(logo);
	    imlib_free_image();
	    imlib_context_set_image(buffer);
	}

	imlib_save_image(outfile);

	imlib_context_set_image(image);
	imlib_free_image();

	imlib_context_set_image(buffer);
	imlib_free_image();

	return 1;
}

__END__

=head1 NAME

Apache::Gallery - mod_perl handler to create an image gallery

=head1 SYNOPSIS

See the INSTALL file in the distribution for installation instructions.

=head1 DESCRIPTION

Apache::Gallery creates an thumbnail index of each directory and allows 
viewing pictures in different resolutions. Pictures are resized on the 
fly and cached. The gallery can be configured and customized in many ways
and a custom copyright image can be added to all the images without
modifying the original.

=head1 CONFIGURATION

In your httpd.conf you set the global options for the gallery. You can
also override each of the options in .htaccess files in your gallery
directories.

The options are set in the httpd.conf/.htaccess file using the syntax:
B<PerlSetVar OptionName 'value'>

Example: B<PerlSetVar InlineDir '/tmp/inline'>

=over 4

=item B<InlineDir>

Full path to the directory Inline should compile the inline c-code
and store the shared objects. This is also where you can find debug
information if the c-code fails to compile.

Defaults to '/tmp'

=item B<GalleryTemplateDir>

Full path to the directory where you placed the templates. This option
can be used both in your global configuration and in .htaccess files,
this way you can have different layouts in different parts of your 
gallery.

No default value, this option is required.

=item B<GalleryInfo>

With this option you can define which EXIF information you would like
to present from the image. The format is: '<MyName => KeyInEXIF, 
MyOtherName => OtherKeyInEXIF'

Examples of keys: B<ShutterSpeedValue>, B<ApertureValue>, B<SubjectDistance>,
and B<Camera>

You can view all the keys from the EXIF header using this perl-oneliner:

perl C<-e> 'use Data::Dumper; use Image::Info qw(image_info); print Dumper(image_info(shift));' filename.jpg

Default is: 'Picture Taken => DateTimeOriginal, Flash => Flash'

=item B<GallerySizes>

Defines which widths images can be scaled to. Images cannot be
scaled to other widths than the ones you define with this option.

The default is '640 1024 1600 2272'

=item B<GalleryThumbnailSize>

Defines the width and height of the thumbnail images. 

Defaults to '100x75'

=item B<GalleryCopyrightImage>

Image you want to blend into your images in the lower right
corner. This could be a transparent png saying "copyright
my name 2001".

Optional.

=item B<GalleryWrapNavigation>

Make the navigation in the picture view wrap around (So Next
at the end displays the first picture, etc.)

Set to 1 or 0, default is 0

=item B<GalleryAllowOriginal>

Allow the user to download the Original picture without
resizing or putting the CopyrightImage on it.

Set to 1 or 0, default is 0

=back

=head1 FEATURES

=over 4

=item B<Rotate images>

Pictures can be rotated on the fly without modifying the original image.

To use this functionality you have to create file with the name of the 
picture you want rotated appened with ".rotate". The file should include 
a number where these numbers are supported:

	"1", rotates clockwise by 90 degree
	"2", rotates clockwise by 180 degrees
	"3", rotates clockwise by 270 degrees

So if we want to rotate "Picture1234.jpg" 90 degrees clockwise we would
create a file in the same directory called "Picture1234.jpg.rotate" with
the number 1 inside of it.

=item B<Comments>

To include comments for each picture you create files called 
picture.jpg.comment where the first line can contain "TITLE: New
title" which will be the title of the page, and a comment on the
following lines.

Example:
TITLE: This is the new title of the page
And this is the comment.<br>
And this is line two of the comment.

=back

=head1 DEPENDENCIES

=over 4

=item B<Perl 5.6>

=item B<Apache with mod_perl>

=item B<Apache::Request>

=item B<URI::Escape>

=item B<Image::Info>

=item B<CGI::FastTemplate>

=item B<Inline::C>

=item B<X11 libraries>
(ie, XFree86)

=item B<Imlib2>
Remember the -dev package when using rpm, deb or other package formats!

=back

=head1 AUTHOR

Michael Legart <michael@legart.dk>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2001-2002 Michael Legart <michael@legart.dk>

Templates designed by Thomas Kjaer <tk@lnx.dk>

Apache::Gallery is free software and is released under the Artistic License.
See B<http://www.perl.com/language/misc/Artistic.html> for details.

The video icons are from the GNOME project. B<http:://www.gnome.org/>

=head1 THANKS

Thanks to Thomas Kjaer for templates and design of B<http://apachegallery.dk>
and thanks to Thomas Eibner for patches.

=head1 SEE ALSO

L<perl>, L<mod_perl>, L<Apache::Request>, L<Inline::C>, L<CGI::FastTemplate>,
and L<Image::Info>.

=cut