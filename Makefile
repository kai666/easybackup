BASHS=		$(wildcard *.bash)
SRC=		${BASHS}
SYNTAX=		$(addsuffix .syntax, ${SRC})

all:	syntax

syntax: ${SYNTAX}

%.bash.syntax: %.bash
	bash -n $< && date > $@

