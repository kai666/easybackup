BASHS=		$(wildcard *.bash)
SRC=		${BASHS}
SYNTAX=		$(addsuffix .syntax, ${SRC})

PACKAGE=	easybackup-0.1
DEB=		${PACKAGE}.deb

INSTALL_SCRIPT=	install -m 0755
INSTALL_DIR=	install -m 0755 -d
INSTALL_DATA=	install -m 0644

all:	syntax

syntax: ${SYNTAX}

%.bash.syntax: %.bash
	bash -n $< && date > $@

DEBROOT=debian

deb: ${DEB}

${DEB}:
	${INSTALL_DIR} ${DEBROOT}/usr
	${INSTALL_DIR} ${DEBROOT}/usr/bin
	${INSTALL_DIR} ${DEBROOT}/usr/share
	${INSTALL_DIR} ${DEBROOT}/usr/share/${PACKAGE}
	${INSTALL_SCRIPT} easybackup.bash ${DEBROOT}/usr/bin/easybackup
	${INSTALL_SCRIPT} easybackupd.bash ${DEBROOT}/usr/bin/easybackupd
	git describe --abbrev=8 --dirty --always --tags > ${DEBROOT}/usr/share/${PACKAGE}/gitref
	fakeroot dpkg-deb --build ${DEBROOT}
	mv ${DEBROOT}.deb ${DEB}
	echo "Built $@: `ls -l $@`"

clean:
	rm -rf ${DEBROOT}/[a-z]*
	rm -f ${DEB}
	rm -f ${SYNTAX}

