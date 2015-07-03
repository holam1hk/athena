# Test script for Newtonian hydro linear wave convergence in 2D

# Modules
import numpy as np
import math
import scripts.utils.athena as athena
import scripts.utils.comparison as comparison

# Parameters
wave_flags = range(5)
res_low = 64
res_high = 128
cutoff = 1.8
amp = 1.0e-6
gamma = 5.0/3.0
vflow = 0.1

# Prepare Athena++
def prepare():
  athena.configure(
      prob='linear_wave',
      coord='cartesian',
      flux='hllc')
  athena.make()

# Run Athena++
def run():
  wavespeeds = wavespeeds_hydro()
  for wave_flag in wave_flags:
    time = 1.0 / abs(wavespeeds[wave_flag])
    arguments = [
        'job/problem_id=hydro_wave_{0}_low'.format(wave_flag),
        'mesh/nx1=' + repr(res_low),
        'mesh/nx2=' + repr(res_low/4),
        'mesh/x1min=0.0', 'mesh/x1max=1.0', 'mesh/x2min=-0.5', 'mesh/x2max=0.5',
        'time/tlim=' + repr(time),
        'output1/dt=' + repr(time),
        'output2/dt=' + repr(time), 'output2/file_type=tab',
        'fluid/gamma=' + repr(gamma),
        'problem/wave_flag=' + repr(wave_flag), 'problem/amp=' + repr(amp),
        'problem/vflow=' + repr(vflow)]
    athena.run('hydro/athinput.linear_wave2d', arguments)
    arguments[0] = 'job/problem_id=hydro_wave_{0}_high'.format(wave_flag)
    arguments[1] = 'mesh/nx1=' + repr(res_high)
    arguments[2] = 'mesh/nx2=' + repr(res_high/4)
    athena.run('hydro/athinput.linear_wave2d', arguments)

# Analyze outputs
def analyze():

  # Specify tab file columns
  headings = ('x', 'y', 'rho', 'pgas', 'vx', 'vy', 'vz')

  # Check that convergence is attained for each wave
  for wave_flag in wave_flags:

    # Read low and high resolution initial and final states
    prim_initial_low = athena.read_tab(
        'bin/hydro_wave_{0}_low.block0.out2.00000.tab'.format(wave_flag),
        headings=headings, dimensions=2)
    prim_initial_high = athena.read_tab(
        'bin/hydro_wave_{0}_high.block0.out2.00000.tab'.format(wave_flag),
        headings=headings, dimensions=2)
    prim_final_low = athena.read_tab(
        'bin/hydro_wave_{0}_low.block0.out2.00001.tab'.format(wave_flag),
        headings=headings, dimensions=2)
    prim_final_high = athena.read_tab(
        'bin/hydro_wave_{0}_high.block0.out2.00001.tab'.format(wave_flag),
        headings=headings, dimensions=2)

    # Calculate overall errors for low and high resolution runs
    epsilons_low = []
    epsilons_high = []
    for quantity in headings[2:]:
      qi = prim_initial_low[quantity][0,:,:].flatten()
      qf = prim_final_low[quantity][0,:,:].flatten()
      epsilons_low.append(math.fsum(abs(qf-qi)) / (res_low**2/4))
      qi = prim_initial_high[quantity][0,:,:].flatten()
      qf = prim_final_high[quantity][0,:,:].flatten()
      epsilons_high.append(math.fsum(abs(qf-qi)) / (res_high**2/4))
    epsilons_low = np.array(epsilons_low)
    epsilons_high = np.array(epsilons_high)
    epsilon_low = (math.fsum(epsilons_low**2) / len(epsilons_low))**0.5 / amp
    epsilon_high = (math.fsum(epsilons_high**2) / len(epsilons_high))**0.5 / amp

    # Test fails if convergence is not at least that specified by cutoff
    if epsilon_high / epsilon_low > (float(res_low) / float(res_high))**cutoff:
      return False

  # All waves must have converged
  return True

# Hydro wavespeed calculator
# Implements (A2) from Stone et al. 2008, ApJS 178 137 (S)
def wavespeeds_hydro():

  # Set fixed primitives
  rho = 1.0
  pgas = 1.0/gamma
  vx = vflow
  vy = 0.0
  vz = 0.0

  # Handle simple entropy case
  wavespeeds = np.empty(5)
  wavespeeds[1] = vx
  wavespeeds[2] = vx
  wavespeeds[3] = vx

  # Calculate sound speeds
  cs = (gamma * pgas / rho)**0.5
  wavespeeds[0] = vx - cs
  wavespeeds[4] = vx + cs
  return wavespeeds