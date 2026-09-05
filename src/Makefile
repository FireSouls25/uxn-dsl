# Makefile for Etal compiler (new layout: lib/ + bin/)
OCAMLC = ocamlc
OCAMLOPT = ocamlopt
OCAMLDEP = ocamldep

SRCS_LIB = lib/ast.ml lib/token.ml lib/lexer.ml lib/parser.ml lib/types.ml lib/expand.ml lib/loader.ml lib/codegen.ml
SRCS_BIN = bin/etal.ml
SRCS = $(SRCS_LIB) $(SRCS_BIN)
OBJS_LIB = $(SRCS_LIB:.ml=.cmo)
OBJS_BIN = $(SRCS_BIN:.ml=.cmo)
OBJS = $(OBJS_LIB) $(OBJS_BIN)

all: etal

etal: $(OBJS)
	$(OCAMLC) -o etal $(OBJS)

lib/%.cmo: lib/%.ml
	$(OCAMLC) -I lib -c $< -o $@

bin/%.cmo: bin/%.ml
	$(OCAMLC) -I lib -c $< -o $@

lib/%.cmx: lib/%.ml
	$(OCAMLOPT) -I lib -c $< -o $@

bin/%.cmx: bin/%.ml
	$(OCAMLOPT) -I lib -c $< -o $@

.depend: $(SRCS)
	$(OCAMLDEP) $(SRCS) > .depend

-include .depend

clean:
	rm -f lib/*.cmo lib/*.cmi lib/*.cmx lib/*.o \
	      bin/*.cmo bin/*.cmi bin/*.cmx bin/*.o \
	      *.cmo *.cmi *.cmx *.o etal .depend
	rm -rf _build

.PHONY: all clean
