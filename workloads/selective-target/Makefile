CXX ?= nvcc
CXXFLAGS ?= -O2 -cudart shared

.PHONY: all clean

all: selective-target

selective-target: src/main.cu
	$(CXX) $(CXXFLAGS) -o $@ $<

clean:
	rm -f selective-target
