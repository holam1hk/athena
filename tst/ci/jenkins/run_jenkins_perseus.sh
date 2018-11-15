#!/usr/bin/env bash

# SCRIPT: run_jenkins_perseus.sh
# AUTHOR: Kyle Gerard Felker - kfelker@princeton.edu
# DATE: 4/10/2018
# PURPOSE: Run style and regression test suites using PICSciE's Jenkins server for continuous
# integration (CI) Current workers include 4x Intel Broadwell nodes on Perseus cluster.

# USAGE: salloc -N1 -n4 --time=0:60:00 ./run_jenkins_perseus.sh
# or similar command in the Jenkins build "Execute shell" step (run from athena/ root dir)

set -e # terminate script at first error/non-zero exit status
# Store absolute path of project's root directory for Lcov (realpath is GNU coreutils, not macOS)
athena_rel_path='./'
athena_abs_path=$(realpath $athena_rel_path)

# Install Python dependencies
pip install -q --user h5py # outputs/all_outputs.py uses athena_read.athdf() reader
pip install -q --user flake8

# Build step #0: Test source code style consistency
# step #0a: lint Python files
python -m flake8
echo "Finished linting Python files with flake8"

# step #0b: lint C++ files
cd tst/style/; ./cpplint_athena.sh
cd ../regression/

# Build step #1: regression tests using GNU compiler and OpenMPI library
module purge
# module load rh # latest GNU compiler
module load openmpi/gcc/1.10.2/64 # openmpi/gcc/3.0.0/64 does not work right now
# Do NOT "module load hdf5" = hdf5/intel-17.0/openmpi-1.10.2/1.10.0
# output/all_outputs.py regression test uses non-MPI HDF5 writer
# (Perseus will error w/ missing mpi.h header if MPI HDF5 is loaded w/o mpicxx)
# grav/ regression tests require MPI and FFTW
module load hdf5/gcc/1.10.0
module load fftw/gcc/3.3.4
module list

# Lcov command stub used for capturing tracefile and for combining multiple tracefiles:
lcov_cmd="lcov --rc lcov_branch_coverage=1 --no-external --gcov-tool=gcov"
regression_abs_path=$(pwd)
lcov_capture_cmd="${lcov_cmd} --directory=${regression_abs_path}/obj/ --capture --base-directory=${athena_abs_path}"

# Run regression test sets. Need to specify Slurm mpirun wrapper, srun
# In order to condense the build log, --silent option suppresses only the stdout of Makefile calls. Don't use with pgen_compile.py:
time python ./run_tests.py pgen/pgen_compile --config=--cflag="$(../ci/set_warning_cflag.sh g++)"
# For (most) regression tests compiled with GCC, perform Gcov code coverage analysis via Lcov front end:
time python ./run_tests.py pgen/hdf5_reader_serial --coverage="${lcov_capture_cmd}" --silent
time python ./run_tests.py grav --coverage="${lcov_capture_cmd}" --silent
time python ./run_tests.py mpi --mpirun=srun --coverage="${lcov_capture_cmd}" --silent
time python ./run_tests.py omp --coverage="${lcov_capture_cmd}" --silent
time python ./run_tests.py hybrid --mpirun=srun --coverage="${lcov_capture_cmd}" --silent
time python ./run_tests.py hydro --coverage="${lcov_capture_cmd}" --silent
time python ./run_tests.py amr --coverage="${lcov_capture_cmd}" --silent
time python ./run_tests.py outputs --coverage="${lcov_capture_cmd}" --silent
time python ./run_tests.py sr --coverage="${lcov_capture_cmd}" --silent
time python ./run_tests.py curvilinear --coverage="${lcov_capture_cmd}" --silent
time python ./run_tests.py symmetry --coverage="${lcov_capture_cmd}" --silent
# Exclude gr/compile*.py regression tests from code coverage analysis (nothing is executed in these tests):
time python ./run_tests.py gr/compile_kerr-schild gr/compile_minkowski gr/compile_schwarzschild --silent
time python ./run_tests.py gr/mhd_shocks_hlld gr/mhd_shocks_hlle gr/mhd_shocks_llf --coverage="${lcov_capture_cmd}" --silent
time python ./run_tests.py gr/hydro_shocks_hllc gr/hydro_shocks_hlle gr/hydro_shocks_llf --coverage="${lcov_capture_cmd}" --silent
time python ./run_tests.py gr/hydro_shocks_hlle_no_transform gr/hydro_shocks_llf_no_transform --coverage="${lcov_capture_cmd}" --silent
# For regression tests with unacceptably long runtimes with -O0 optimization, "sample" the code coverage by running each test twice:
# - 1x normally (-O3) without --coverage=CMD to check correctness
# - 1x with --coverage=CMD (and hence -O0) and small cycle limit, ignoring failure in subsequent test.analyze() step
time python ./run_tests.py mhd --coverage="${lcov_capture_cmd}" -r="time/nlim=10" --silent || true
time python ./run_tests.py mhd --silent  # (mhd/mhd_linwave.py is currenlty the slowest regression test):

time python ./run_tests.py shearingbox --coverage="${lcov_capture_cmd}" -r="time/nlim=10" --silent || true
time python ./run_tests.py shearingbox --silent

time python ./run_tests.py diffusion --coverage="${lcov_capture_cmd}" -r="time/nlim=10" --silent || true
time python ./run_tests.py diffusion --silent

# High-order solver regression tests w/ GCC
time python ./run_tests.py hydro4 --coverage="${lcov_capture_cmd}" -r="time/nlim=10" --silent || true
time python ./run_tests.py hydro4 --silent

# Swap serial HDF5 library module for parallel HDF5 library:
module unload hdf5/gcc/1.10.0
module load hdf5/gcc/openmpi-1.10.2/1.10.0
module list
# Workaround issue with parallel HDF5 modules compiled with OpenMPI on Perseus--- linker still takes serial HDF5 library in /usr/lib64/
# due to presence of -L flag in mpicxx wrapper that overrides LIBRARY_PATH environment variable
time python ./run_tests.py pgen/hdf5_reader_parallel --coverage="${lcov_capture_cmd}" --mpirun=srun --config=--lib=/usr/local/hdf5/gcc/openmpi-1.10.2/1.10.0/lib64 --silent

# Combine Lcov tracefiles from individaul regression tests:
# All .info files in current working directory tst/regression/ -> lcov.info
# (remove '-maxdepth 1' to recursively search subfolders for more .info)
while read filename; do
    lcov_input_files="$lcov_input_files -a \"$filename\""
done < <( find . -maxdepth 1 -name '*.info' )
eval "${lcov_cmd}" "${lcov_input_files}" -o lcov.info

# (temporary) Generate Lcov HTML report and backup to home directory on Perseus (not used by Codecov):
gendesc scripts/tests/test_descriptions.txt --output-filename ./regression_tests.desc
genhtml --legend --show-details --keep-descriptions --description-file=regression_tests.desc --branch-coverage -o regression_tests_html_summary lcov.info
cp -r regression_tests_html_summary $HOME
cp lcov.info $HOME

# Build step #2: regression tests using Intel compiler and MPI library
module purge
# automatically use latest default version of these libraries as Princeton Research Computing updates them:
module load intel/17.0/64/17.0.5.239 # intel ---intel/19.0/64/19.0.0.117
module load intel-mpi/intel/2017.5/64 # intel-mpi --- intel-mpi/intel/2018.3/64
# pinning these modules to a specific version, since new library versions are rarely compiled:
module load fftw/gcc/3.3.4
module load hdf5/intel-17.0/1.10.0 # hdf5/intel-17.0/intel-mpi/1.10.0
# do not mix w/ "module load rh" to ensure that Intel shared libraries are used by the loader (especially OpenMP?)
module list

time python ./run_tests.py pgen/pgen_compile --config=--cxx=icc --config=--cflag="$(../ci/set_warning_cflag.sh icc)"
time python ./run_tests.py pgen/hdf5_reader_serial --silent
time python ./run_tests.py grav --config=--cxx=icc --mpirun=srun --silent
time python ./run_tests.py mpi --config=--cxx=icc --mpirun=srun --silent
time python ./run_tests.py omp --config=--cxx=icc --silent
time python ./run_tests.py hybrid --config=--cxx=icc --mpirun=srun --silent
time python ./run_tests.py hydro --config=--cxx=icc --silent
time python ./run_tests.py mhd --config=--cxx=icc --silent
time python ./run_tests.py amr --config=--cxx=icc --silent
time python ./run_tests.py outputs --config=--cxx=icc --silent
time python ./run_tests.py sr --config=--cxx=icc --silent
time python ./run_tests.py gr --config=--cxx=icc --silent
time python ./run_tests.py curvilinear --config=--cxx=icc --silent
time python ./run_tests.py shearingbox --config=--cxx=icc --silent
time python ./run_tests.py diffusion --config=--cxx=icc --silent
time python ./run_tests.py symmetry --config=--cxx=icc --silent

# High-order solver regression tests w/ Intel compiler
time python ./run_tests.py hydro4 --config=--cxx=icc --silent

# Swap serial HDF5 library module for parallel HDF5 library:
module unload  hdf5/intel-17.0/1.10.0
module load hdf5/intel-17.0/intel-mpi/1.10.0
module list
# Workaround issue with parallel HDF5 modules compiled with OpenMPI on Perseus--- linker still takes serial HDF5 library in /usr/lib64/
# due to presence of -L flag in mpicxx wrapper that overrides LIBRARY_PATH environment variable
time python ./run_tests.py pgen/hdf5_reader_parallel --config=--cxx=icc --mpirun=srun --config=--lib=/usr/local/hdf5/intel-17.0/intel-mpi/1.10.0/lib64 --silent

# Test OpenMP 4.5 SIMD-enabled function correctness by disabling IPO and forced inlining w/ Intel compiler flags
# Check subset of regression test sets to try most EOS functions (which heavily depend on vectorization) that are called in rsolvers
time python ./run_tests.py pgen/pgen_compile --config=--cxx=icc-debug --config=--cflag="$(../ci/set_warning_cflag.sh icc)"
time python ./run_tests.py hydro --config=--cxx=icc-debug --silent
time python ./run_tests.py mhd --config=--cxx=icc-debug --silent
time python ./run_tests.py sr --config=--cxx=icc-debug --silent
time python ./run_tests.py gr --config=--cxx=icc-debug --silent

set +e
# end regression tests

# Upload tracefile for Codecov analysis of test coverage reports (Lcov tracefile must be named "lcov.info"):
# curl-pipe to Codecov Bash Uploader (recommended approach for Jenkins)
curl -s https://codecov.io/bash | bash -s - -X gcov -t ccdc959e-e2c3-4811-95c6-512151b39471 || echo "Codecov did not collect coverage reports"
