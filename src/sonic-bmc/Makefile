ROOT_DIR := $(dir $(abspath $(firstword $(MAKEFILE_LIST))))
SRC_DIR := $(ROOT_DIR)/sonic-bmc
export PATH

GIT := git
# Makefile

# Define the default target
.DEFAULT_GOAL := all

# Specify the CMake build directory
BUILD_DIR := build

# Build targets
.PHONY: all build clean clone

clone:
	echo "Building sonic-bmc package...  $(ROOT_DIR)"
	@if [ ! -d "$(SRC_DIR)" ]; then \
		$(GIT) clone https://github.com/micasyang/sonic-bmc.git $(SRC_DIR); \
	else \
		echo "sonic-bmc already exists."; \
	fi

build: clone
	cd $(SRC_DIR) && make

all: install

clean:
	@rm -rf $(BUILD_DIR)

install: build
	cp $(SRC_DIR)/*.deb $(ROOT_DIR)