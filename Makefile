ENTRYPOINT = entrypoint/entrypoint

all: $(ENTRYPOINT)

$(ENTRYPOINT): entrypoint/entrypoint.c
	gcc -O2 -static -Wall -o $@ entrypoint/entrypoint.c

