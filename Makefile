BASHS=		$(wildcard *.bash)
SRC=		${BASHS}
SYNTAX=		$(addsuffix .syntax, ${SRC})
SYNTAX+=	easybackup.postinst.syntax easybackup.postrm.syntax

PACKAGE=	easybackup-0.1
DEB=		${PACKAGE}.deb

INSTALL_SCRIPT=	install -m 0755
INSTALL_DIR=	install -m 0755 -d
INSTALL_DATA=	install -m 0644

all:	syntax

syntax: ${SYNTAX}

%.bash.syntax: %.bash
	bash -n $< && date > $@

%.postinst.syntax: %.postinst
	bash -n $< && date > $@

%.postrm.syntax: %.postrm
	bash -n $< && date > $@

DEBROOT=${PACKAGE}

deb: ${DEB}

${DEB}:
	${INSTALL_DIR} ${DEBROOT}/DEBIAN
	${INSTALL_DATA} control ${DEBROOT}/DEBIAN/
	${INSTALL_DIR} ${DEBROOT}/usr/bin
	${INSTALL_DIR} ${DEBROOT}/usr/share/${PACKAGE}
	${INSTALL_DIR} ${DEBROOT}/lib/systemd/system
	${INSTALL_SCRIPT} easybackup.bash ${DEBROOT}/usr/bin/easybackup
	${INSTALL_SCRIPT} easybackupd.bash ${DEBROOT}/usr/bin/easybackupd
	git describe --abbrev=8 --dirty --always --tags > ${DEBROOT}/usr/share/${PACKAGE}/gitref
	${INSTALL_DATA} easybackup.service ${DEBROOT}/lib/systemd/system
	${INSTALL_SCRIPT} easybackup.postinst ${DEBROOT}/DEBIAN/postinst
	${INSTALL_SCRIPT} easybackup.postrm ${DEBROOT}/DEBIAN/postrm
	${INSTALL_DIR} ${DEBROOT}/etc/cron.weekly
	${INSTALL_SCRIPT} easybackup.weekly.bash ${DEBROOT}/etc/cron.weekly/92-easybackup.weekly
	fakeroot dpkg-deb --build ${DEBROOT}
	echo "Built $@: `ls -l $@`"

clean:
	rm -rf ${DEBROOT}
	rm -f ${DEB}
	rm -f ${SYNTAX}

