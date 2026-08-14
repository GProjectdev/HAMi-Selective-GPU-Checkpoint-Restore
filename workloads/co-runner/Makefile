CXX ?= nvcc
CXXFLAGS ?= -O2

.PHONY: all clean

all: co-runner

co-runner: src/main.cu
	$(CXX) $(CXXFLAGS) -o $@ $<

clean:
	rm -f co-runner

