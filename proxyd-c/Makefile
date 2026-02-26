ifneq ($(THEOS),)
TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TOOL_NAME = luminaproxyd
luminaproxyd_FILES = src/luminaproxyd.c
luminaproxyd_CFLAGS = -std=c11 -O2 -Wall -Wextra -Wno-unused-parameter
luminaproxyd_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk
else
CC ?= cc
CFLAGS ?= -std=c11 -O2 -Wall -Wextra -pthread
LDFLAGS ?= -pthread
OUT ?= luminaproxyd
SRC = src/luminaproxyd.c

.PHONY: all clean run

all: $(OUT)

$(OUT): $(SRC)
	$(CC) $(CFLAGS) -o $@ $(SRC) $(LDFLAGS)

run: $(OUT)
	./$(OUT) ./example-config.json

clean:
	rm -f $(OUT)
endif

