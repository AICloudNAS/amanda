# Makefile for Amanda wrapper programs.

include $(top_srcdir)/config/automake/vars.am
include $(top_srcdir)/config/automake/scripts.am
include $(top_srcdir)/config/automake/installperms.am
include $(top_srcdir)/config/automake/precompile.am

AM_CPPFLAGS =	-I$(top_builddir)/common-src \
		-I$(top_srcdir)/common-src \
		-I$(top_srcdir)/client-src \
		-I$(top_srcdir)/amandad-src \
		-I$(top_srcdir)/gnulib

LINT=$(AMLINT)
LINTFLAGS=$(AMLINTFLAGS)

AM_CFLAGS = $(AMANDA_WARNING_CFLAGS) $(AMANDA_FILE_CFLAGS)
AM_LDFLAGS = $(AMANDA_STATIC_LDFLAGS) $(AS_NEEDED_FLAGS)

applicationexec_SCRIPTS_SHELL = script-fail

applicationexec_SCRIPTS_PERL = script-email \
	     amlog-script \
	     ampgsql \
	     amzfs-sendrecv \
	     amzfs-snapshot \
	     amrandom \
	     amraw \
	     amsamba \
	     amsuntar

amlibexec_PROGRAMS = teecount

#We use two variables, applicationdir applicationexecdir, to segregate the
#platform-independent (applicationdir) files installed by install-data from the
#platform-dependent files (applicationexecdir) installed by install-exec.
#Automake recognizes the 'exec' substring in the variable name.  From the
#Automake manual: "Any variable using a user-defined directory prefix with
#‘exec’ in the name (e.g., myexecbin_PROGRAMS) is installed by install-exec.
#All other user-defined prefixes are installed by install-data." (section 12.2)
applicationexecdir = $(APPLICATION_DIR)
applicationdir = $(APPLICATION_DIR)
applicationexec_PROGRAMS = ambsdtar amgtar amstar
applicationexec_SCRIPTS = $(applicationexec_SCRIPTS_PERL) $(applicationexec_SCRIPTS_SHELL)

SCRIPTS_SHELL = $(applicationexec_SCRIPTS_SHELL)
SCRIPTS_PERL = $(applicationexec_SCRIPTS_PERL)

CLEANFILES += $(SCRIPTS_PERL) $(SCRIPTS_SHELL)
DISTCLEANFILES += config.log

LDADD = ../common-src/libamanda.la \
	../client-src/libamclient.la \
	../amandad-src/libamandad.la \
	../common-src/libamanda.la \
	../gnulib/libgnu.la

if WANT_SETUID_CLIENT
INSTALLPERMS_exec = dest=$(applicationdir) chown=root:setuid chmod=04750 \
		    ambsdtar amgtar amstar
endif
