twipper
=======

A small perl-based CLI twitter client; works well with conky integration for reading, at least for my purposes.

Requirements
=======
Net::OAuth (libnet-oauth-perl)
LWP (libwww-perl)
JSON (libjson-perl)
Module::Load::Conditional (libmodule-load-conditional-perl)
Digest::SHA (libdigest-sha-perl)
Date::Calc (libdate-calc-perl)
Math::Random::Secure (not available in Debian; I like cpanminus, which seems faster and easier to use than cpan)

And, if you want to use the GUI mode,
Tk (perl-tk)

LICENSE
=======
Copyright 2013-2014 Patrick Bogen

This file is part of twipper.

twipper is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

twipper is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with twipper.  If not, see <http://www.gnu.org/licenses/>.
