PREFIX ?= $(HOME)/.local

.PHONY: all install uninstall clear-cache clean

all:
	meson setup build
	ninja -C build

install:
	-killall convey
	meson setup build --prefix=$(PREFIX) --reconfigure
	meson install -C build

uninstall:
	-killall convey
	ninja -C build uninstall

clear-cache:
	rm -rf ~/.cache/convey-development
	rm -rf ~/.local/share/convey-development
	rm -rf ~/.config/convey-development

clean:
	rm -rvf build
