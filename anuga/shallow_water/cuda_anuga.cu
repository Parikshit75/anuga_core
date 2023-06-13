// CUDA code to implement flux and quantity updates as used 
// in evolve loop



// FIXME SR: this routine doesn't seem to be used in flux calculation, probably used in 
// extrapolation
__device__ int __find_qmin_and_qmax(double dq0, double dq1, double dq2,
  double *qmin, double *qmax)
{
// Considering the centroid of an FV triangle and the vertices of its
// auxiliary triangle, find
// qmin=min(q)-qc and qmax=max(q)-qc,
// where min(q) and max(q) are respectively min and max over the
// four values (at the centroid of the FV triangle and the auxiliary
// triangle vertices),
// and qc is the centroid
// dq0=q(vertex0)-q(centroid of FV triangle)
// dq1=q(vertex1)-q(vertex0)
// dq2=q(vertex2)-q(vertex0)

// This is a simple implementation
*qmax = fmax(fmax(dq0, fmax(dq0 + dq1, dq0 + dq2)), 0.0);
*qmin = fmin(fmin(dq0, fmin(dq0 + dq1, dq0 + dq2)), 0.0);

return 0;
}

// FIXME SR: this routine doesn't seem to be used in flux calculation, probably used in 
// extrapolation
__device__ int __limit_gradient(double *dqv, double qmin, double qmax, double beta_w)
{
// Given provisional jumps dqv from the FV triangle centroid to its
// vertices/edges, and jumps qmin (qmax) between the centroid of the FV
// triangle and the minimum (maximum) of the values at the auxiliary triangle
// vertices (which are centroids of neighbour mesh triangles), calculate a
// multiplicative factor phi by which the provisional vertex jumps are to be
// limited

int i;
double r = 1000.0, r0 = 1.0, phi = 1.0;
static double TINY = 1.0e-100; // to avoid machine accuracy problems.
// FIXME: Perhaps use the epsilon used elsewhere.

// Any provisional jump with magnitude < TINY does not contribute to
// the limiting process.
// return 0;

for (i = 0; i < 3; i++)
{
if (dqv[i] < -TINY)
r0 = qmin / dqv[i];

if (dqv[i] > TINY)
r0 = qmax / dqv[i];

r = fmin(r0, r);
}

phi = fmin(r * beta_w, 1.0);
// phi=1.;
dqv[0] = dqv[0] * phi;
dqv[1] = dqv[1] * phi;
dqv[2] = dqv[2] * phi;

return 0;
}

// Computational function for rotation
__device__ void __rotate(double *q, double n1, double n2)
{
  /*Rotate the last  2 coordinates of q (q[1], q[2])
    from x,y coordinates to coordinates based on normal vector (n1, n2).

    Result is returned in array 2x1 r
    To rotate in opposite direction, call rotate with (q, n1, -n2)

    Contents of q are changed by this function */

  double q1, q2;

  // Shorthands
  q1 = q[1]; // x coordinate
  q2 = q[2]; // y coordinate

  // Rotate
  q[1] = n1 * q1 + n2 * q2;
  q[2] = -n2 * q1 + n1 * q2;

}

// Innermost flux function (using stage w=z+h)
__device__ void __flux_function_central(double *q_left, double *q_right,
                            double h_left, double h_right,
                            double hle, double hre,
                            double n1, double n2,
                            double epsilon,
                            double ze,
                            double limiting_threshold,
                            double g,
                            double *edgeflux, double *max_speed,
                            double *pressure_flux, double hc,
                            double hc_n,
                            long low_froude)
{

  /*Compute fluxes between volumes for the shallow water wave equation
    cast in terms of the 'stage', w = h+z using
    the 'central scheme' as described in

    Kurganov, Noelle, Petrova. 'Semidiscrete Central-Upwind Schemes For
    Hyperbolic Conservation Laws and Hamilton-Jacobi Equations'.
    Siam J. Sci. Comput. Vol. 23, No. 3, pp. 707-740.

    The implemented formula is given in equation (3.15) on page 714

    FIXME: Several variables in this interface are no longer used, clean up
  */

  int i;

  double uh_left, vh_left, u_left;
  double uh_right, vh_right, u_right;
  double s_min, s_max, soundspeed_left, soundspeed_right;
  double denom, inverse_denominator;
  double tmp, local_fr, v_right, v_left;
  double q_left_rotated[3], q_right_rotated[3], flux_right[3], flux_left[3];

  if (h_left == 0. && h_right == 0.)
  {
    // Quick exit
    memset(edgeflux, 0, 3 * sizeof(double));
    *max_speed = 0.0;
    *pressure_flux = 0.;
    return;
  }
  // Copy conserved quantities to protect from modification
  q_left_rotated[0] = q_left[0];
  q_right_rotated[0] = q_right[0];
  q_left_rotated[1] = q_left[1];
  q_right_rotated[1] = q_right[1];
  q_left_rotated[2] = q_left[2];
  q_right_rotated[2] = q_right[2];

  // Align x- and y-momentum with x-axis
  __rotate(q_left_rotated, n1, n2);
  __rotate(q_right_rotated, n1, n2);

  // Compute speeds in x-direction
  // w_left = q_left_rotated[0];
  uh_left = q_left_rotated[1];
  vh_left = q_left_rotated[2];
  if (hle > 0.0)
  {
    tmp = 1.0 / hle;
    u_left = uh_left * tmp; // max(h_left, 1.0e-06);
    uh_left = h_left * u_left;
    v_left = vh_left * tmp; // Only used to define local_fr
    vh_left = h_left * tmp * vh_left;
  }
  else
  {
    u_left = 0.;
    uh_left = 0.;
    vh_left = 0.;
    v_left = 0.;
  }

  // u_left = _compute_speed(&uh_left, &hle,
  //             epsilon, h0, limiting_threshold);

  // w_right = q_right_rotated[0];
  uh_right = q_right_rotated[1];
  vh_right = q_right_rotated[2];
  if (hre > 0.0)
  {
    tmp = 1.0 / hre;
    u_right = uh_right * tmp; // max(h_right, 1.0e-06);
    uh_right = h_right * u_right;
    v_right = vh_right * tmp; // Only used to define local_fr
    vh_right = h_right * tmp * vh_right;
  }
  else
  {
    u_right = 0.;
    uh_right = 0.;
    vh_right = 0.;
    v_right = 0.;
  }
  // u_right = _compute_speed(&uh_right, &hre,
  //               epsilon, h0, limiting_threshold);

  // Maximal and minimal wave speeds
  soundspeed_left = sqrt(g * h_left);
  soundspeed_right = sqrt(g * h_right);
  // soundspeed_left  = sqrt(g*hle);
  // soundspeed_right = sqrt(g*hre);

  // Something that scales like the Froude number
  // We will use this to scale the diffusive component of the UH/VH fluxes.

  // low_froude can have values 0, 1, 2
  if (low_froude == 1)
  {
    local_fr = sqrt(
        fmax(0.001, fmin(1.0,
                         (u_right * u_right + u_left * u_left + v_right * v_right + v_left * v_left) /
                             (soundspeed_left * soundspeed_left + soundspeed_right * soundspeed_right + 1.0e-10))));
  }
  else if (low_froude == 2)
  {
    local_fr = sqrt((u_right * u_right + u_left * u_left + v_right * v_right + v_left * v_left) /
                    (soundspeed_left * soundspeed_left + soundspeed_right * soundspeed_right + 1.0e-10));
    local_fr = sqrt(fmin(1.0, 0.01 + fmax(local_fr - 0.01, 0.0)));
  }
  else
  {
    local_fr = 1.0;
  }
  // printf("local_fr %e \n:", local_fr);

  s_max = fmax(u_left + soundspeed_left, u_right + soundspeed_right);
  if (s_max < 0.0)
  {
    s_max = 0.0;
  }

  // if( hc < 1.0e-03){
  //   s_max = 0.0;
  // }

  s_min = fmin(u_left - soundspeed_left, u_right - soundspeed_right);
  if (s_min > 0.0)
  {
    s_min = 0.0;
  }

  // if( hc_n < 1.0e-03){
  //   s_min = 0.0;
  // }

  // Flux formulas
  flux_left[0] = u_left * h_left;
  flux_left[1] = u_left * uh_left; //+ 0.5*g*h_left*h_left;
  flux_left[2] = u_left * vh_left;

  flux_right[0] = u_right * h_right;
  flux_right[1] = u_right * uh_right; //+ 0.5*g*h_right*h_right;
  flux_right[2] = u_right * vh_right;

  // Flux computation
  denom = s_max - s_min;
  if (denom < epsilon)
  {
    // Both wave speeds are very small
    //memset(edgeflux, 0, 3 * sizeof(double)); 
    edgeflux[0] = 0.0;
    edgeflux[1] = 0.0;
    edgeflux[2] = 0.0;


    *max_speed = 0.0;
    //*pressure_flux = 0.0;
    *pressure_flux = 0.5 * g * 0.5 * (h_left * h_left + h_right * h_right);
  }
  else
  {
    // Maximal wavespeed
    *max_speed = fmax(s_max, -s_min);

    inverse_denominator = 1.0 / fmax(denom, 1.0e-100);
    for (i = 0; i < 3; i++)
    {
      edgeflux[i] = s_max * flux_left[i] - s_min * flux_right[i];

      // Standard smoothing term
      // edgeflux[i] += 1.0*(s_max*s_min)*(q_right_rotated[i] - q_left_rotated[i]);
      // Smoothing by stage alone can cause high velocities / slow draining for nearly dry cells
      if (i == 0)
        edgeflux[i] += (s_max * s_min) * (fmax(q_right_rotated[i], ze) - fmax(q_left_rotated[i], ze));
      // if(i==0) edgeflux[i] += (s_max*s_min)*(h_right - h_left);
      if (i == 1)
        edgeflux[i] += local_fr * (s_max * s_min) * (uh_right - uh_left);
      if (i == 2)
        edgeflux[i] += local_fr * (s_max * s_min) * (vh_right - vh_left);

      edgeflux[i] *= inverse_denominator;
    }
    // Separate pressure flux, so we can apply different wet-dry hacks to it
    *pressure_flux = 0.5 * g * (s_max * h_left * h_left - s_min * h_right * h_right) * inverse_denominator;

    // Rotate back
    __rotate(edgeflux, n1, -n2);
  }

}


__device__ double __adjust_edgeflux_with_weir(double *edgeflux,
                                   double h_left, double h_right,
                                   double g, double weir_height,
                                   double Qfactor,
                                   double s1, double s2,
                                   double h1, double h2,
                                   double *max_speed_local)
{
  // Adjust the edgeflux to agree with a weir relation [including
  // subergence], but smoothly vary to shallow water solution when
  // the flow over the weir is much deeper than the weir, or the
  // upstream/downstream water elevations are too similar
  double rw, rw2; // 'Raw' weir fluxes
  double rwRat, hdRat, hdWrRat, scaleFlux, minhd, maxhd;
  double w1, w2; // Weights for averaging
  double newFlux;
  double twothirds = (2.0 / 3.0);
  // Following constants control the 'blending' with the shallow water solution
  // They are now user-defined
  // double s1=0.9; // At this submergence ratio, begin blending with shallow water solution
  // double s2=0.95; // At this submergence ratio, completely use shallow water solution
  // double h1=1.0; // At this (tailwater height above weir) / (weir height) ratio, begin blending with shallow water solution
  // double h2=1.5; // At this (tailwater height above weir) / (weir height) ratio, completely use the shallow water solution

  if ((h_left <= 0.0) && (h_right <= 0.0))
  {
    return 0;
  }

  minhd = fmin(h_left, h_right);
  maxhd = fmax(h_left, h_right);
  // 'Raw' weir discharge = Qfactor*2/3*H*(2/3*g*H)**0.5
  rw = Qfactor * twothirds * maxhd * sqrt(twothirds * g * maxhd);
  // Factor for villemonte correction
  rw2 = Qfactor * twothirds * minhd * sqrt(twothirds * g * minhd);
  // Useful ratios
  rwRat = rw2 / fmax(rw, 1.0e-100);
  hdRat = minhd / fmax(maxhd, 1.0e-100);

  // (tailwater height above weir)/weir_height ratio
  hdWrRat = minhd / fmax(weir_height, 1.0e-100);

  // Villemonte (1947) corrected weir flow with submergence
  // Q = Q1*(1-Q2/Q1)**0.385
  rw = rw * pow(1.0 - rwRat, 0.385);

  if (h_right > h_left)
  {
    rw *= -1.0;
  }

  if ((hdRat < s2) & (hdWrRat < h2))
  {
    // Rescale the edge fluxes so that the mass flux = desired flux
    // Linearly shift to shallow water solution between hdRat = s1 and s2
    // and between hdWrRat = h1 and h2

    //
    // WEIGHT WITH RAW SHALLOW WATER FLUX BELOW
    // This ensures that as the weir gets very submerged, the
    // standard shallow water equations smoothly take over
    //

    // Weighted average constants to transition to shallow water eqn flow
    w1 = fmin(fmax(hdRat - s1, 0.) / (s2 - s1), 1.0);

    // Adjust again when the head is too deep relative to the weir height
    w2 = fmin(fmax(hdWrRat - h1, 0.) / (h2 - h1), 1.0);

    newFlux = (rw * (1.0 - w1) + w1 * edgeflux[0]) * (1.0 - w2) + w2 * edgeflux[0];

    if (fabs(edgeflux[0]) > 1.0e-100)
    {
      scaleFlux = newFlux / edgeflux[0];
    }
    else
    {
      scaleFlux = 0.;
    }

    scaleFlux = fmax(scaleFlux, 0.);

    edgeflux[0] = newFlux;

    // FIXME: Do this in a cleaner way
    // IDEA: Compute momentum flux implied by weir relations, and use
    //       those in a weighted average (rather than the rescaling trick here)
    // If we allow the scaling to momentum to be unbounded,
    // velocity spikes can arise for very-shallow-flooded walls
    edgeflux[1] *= fmin(scaleFlux, 10.);
    edgeflux[2] *= fmin(scaleFlux, 10.);
  }

  // Adjust the max speed
  if (fabs(edgeflux[0]) > 0.)
  {
    *max_speed_local = sqrt(g * (maxhd + weir_height)) + fabs(edgeflux[0] / (maxhd + 1.0e-12));
  }
  //*max_speed_local += fabs(edgeflux[0])/(maxhd+1.0e-100);
  //*max_speed_local *= fmax(scaleFlux, 1.0);

  return 0;
}


// FIXME SR: At present reduction is done outside kernel
__device__ double atomicMin_double(double* address, double val)

{

	    unsigned long long int* address_as_ull = (unsigned long long int*) address;

	        unsigned long long int old = *address_as_ull, assumed;

		    do {

	                      assumed = old;
			      old = atomicCAS(address_as_ull, assumed,
							                __double_as_longlong(fmin(val, __longlong_as_double(assumed))));
					        } while (assumed != old);

		        return __longlong_as_double(old);

}
// Parallel loop in cuda_compute_fluxes
// Computational function for flux computation
// need to return local_timestep and boundary_flux_sum_substep
__global__ void _cuda_compute_fluxes_loop_1(double* timestep_k_array,  // InOut
                                    double* boundary_flux_sum_k_array, // InOut
                                    double* max_speed,               // InOut
                                    double* stage_explicit_update,   // InOut
                                    double* xmom_explicit_update,    // InOut
                                    double* ymom_explicit_update,    // InOut

                                    double* stage_centroid_values,
                                    double* stage_edge_values,
                                    double* xmom_edge_values,
                                    double* ymom_edge_values,
                                    double* bed_edge_values,
                                    double* height_edge_values,
                                    double* height_centroid_values,
                                    double* bed_centroid_values,
                                    double* stage_boundary_values,
                                    double* xmom_boundary_values,
                                    double* ymom_boundary_values,
                                    double* areas,
                                    double* normals,
                                    double* edgelengths,
                                    double* radii,
                                    long* tri_full_flag,
                                    long* neighbours,
                                    long* neighbour_edges,
                                    long* edge_flux_type,
                                    long* edge_river_wall_counter,
                                    double* riverwall_elevation,
                                    long* riverwall_rowIndex,
                                    double* riverwall_hydraulic_properties,

                                    long number_of_elements,
                                    long substep_count,
                                    long ncol_riverwall_hydraulic_properties,
                                    double epsilon,
                                    double g,
                                    long low_froude,
                                    double limiting_threshold)
{
  // #pragma omp parallel for simd default(none) shared(D, substep_count, ) \


  long k, i, ki, ki2, n, m, nm, ii;
  long RiverWall_count;
  double max_speed_local, length, inv_area, zl, zr;
  double h_left, h_right;
  double z_half, ql[3], pressuregrad_work;
  double qr[3], edgeflux[3], edge_timestep, normal_x, normal_y;
  double hle, hre, zc, zc_n, Qfactor, s1, s2, h1, h2, pressure_flux, hc, hc_n;
  double h_left_tmp, h_right_tmp, weir_height;

  // Set explicit_update to zero for all conserved_quantities.
  // This assumes compute_fluxes called before forcing terms
  double local_stage_explicit_update = 0.0;
  double local_xmom_explicit_update  = 0.0;
  double local_ymom_explicit_update  = 0.0;

  double local_max_speed = 0.0;
  double local_timestep = 1.0e+100;
  double local_boundary_flux_sum = 0.0;
  double speed_max_last = 0.0;


  //for (k = 0; k < number_of_elements; k++)
  k = blockIdx.x * blockDim.x + threadIdx.x; 
  if(k<number_of_elements)
  {

    // Loop through neighbours and compute edge flux for each
    for (i = 0; i < 3; i++)
    {
      ki = 3 * k + i; // Linear index to edge i of triangle k
      ki2 = 2 * ki;   // k*6 + i*2

      // Get left hand side values from triangle k, edge i
      ql[0] = stage_edge_values[ki];
      ql[1] = xmom_edge_values[ki];
      ql[2] = ymom_edge_values[ki];
      zl =    bed_edge_values[ki];
      hle =   height_edge_values[ki];

      hc = height_centroid_values[k];
      zc = bed_centroid_values[k];

      // Get right hand side values either from neighbouring triangle
      // or from boundary array (Quantities at neighbour on nearest face).
      n = neighbours[ki];
      hc_n = hc;
      zc_n = bed_centroid_values[k];
      if (n < 0)
      {
        // Neighbour is a boundary condition
        m = -n - 1; // Convert negative flag to boundary index

        qr[0] = stage_boundary_values[m];
        qr[1] = xmom_boundary_values[m];
        qr[2] = ymom_boundary_values[m];
        zr = zl;                     // Extend bed elevation to boundary
        hre = fmax(qr[0] - zr, 0.0); // hle;
      }
      else
      {
        // Neighbour is a real triangle
        hc_n = height_centroid_values[n];
        zc_n = bed_centroid_values[n];

        m = neighbour_edges[ki];
        nm = n * 3 + m; // Linear index (triangle n, edge m)

        qr[0] = stage_edge_values[nm];
        qr[1] = xmom_edge_values[nm];
        qr[2] = ymom_edge_values[nm];
        zr = bed_edge_values[nm];
        hre = height_edge_values[nm];
      }

      // Audusse magic for well balancing
      z_half = fmax(zl, zr);

      // Account for riverwalls
      if (edge_flux_type[ki] == 1)
      {
        RiverWall_count = edge_river_wall_counter[ki];

        // Set central bed to riverwall elevation
        z_half = fmax(riverwall_elevation[RiverWall_count - 1], z_half);
      }

      // Define h left/right for Audusse flux method
      h_left = fmax(hle + zl - z_half, 0.);
      h_right = fmax(hre + zr - z_half, 0.);

      normal_x = normals[ki2];
      normal_y = normals[ki2 + 1];

      // Edge flux computation (triangle k, edge i)
      __flux_function_central(ql, qr,
                              h_left, h_right,
                              hle, hre,
                              normal_x, normal_y,
                              epsilon, z_half, limiting_threshold, g,
                              edgeflux, &max_speed_local, &pressure_flux,
                              hc, hc_n, low_froude);

      // Force weir discharge to match weir theory
      if (edge_flux_type[ki] == 1)
      {

        RiverWall_count = edge_river_wall_counter[ki];

        // printf("RiverWall_count %ld\n", RiverWall_count);

        ii = riverwall_rowIndex[RiverWall_count - 1] * ncol_riverwall_hydraulic_properties;

        // Get Qfactor index - multiply the idealised weir discharge by this constant factor
        // Get s1, submergence ratio at which we start blending with the shallow water solution
        // Get s2, submergence ratio at which we entirely use the shallow water solution
        // Get h1, tailwater head / weir height at which we start blending with the shallow water solution
        // Get h2, tailwater head / weir height at which we entirely use the shallow water solution
        Qfactor = riverwall_hydraulic_properties[ii];
        s1 = riverwall_hydraulic_properties[ii + 1];
        s2 = riverwall_hydraulic_properties[ii + 2];
        h1 = riverwall_hydraulic_properties[ii + 3];
        h2 = riverwall_hydraulic_properties[ii + 4];

        weir_height = fmax(riverwall_elevation[RiverWall_count - 1] - fmin(zl, zr), 0.); // Reference weir height

        // Use first-order h's for weir -- as the 'upstream/downstream' heads are
        //  measured away from the weir itself
        h_left_tmp = fmax(stage_centroid_values[k] - z_half, 0.);

        if (n >= 0)
        {
          h_right_tmp = fmax(stage_centroid_values[n] - z_half, 0.);
        }
        else
        {
          h_right_tmp = fmax(hc_n + zr - z_half, 0.);
        }

        // If the weir is not higher than both neighbouring cells, then
        // do not try to match the weir equation. If we do, it seems we
        // can get mass conservation issues (caused by large weir
        // fluxes in such situations)
        if (riverwall_elevation[RiverWall_count - 1] > fmax(zc, zc_n))
        {
          // Weir flux adjustment
          __adjust_edgeflux_with_weir(edgeflux, h_left_tmp, h_right_tmp, g,
                                      weir_height, Qfactor,
                                      s1, s2, h1, h2, &max_speed_local);
        }
      }

      // Multiply edgeflux by edgelength
      length = edgelengths[ki];
      edgeflux[0] = -edgeflux[0] * length;
      edgeflux[1] = -edgeflux[1] * length;
      edgeflux[2] = -edgeflux[2] * length;

      // bedslope_work contains all gravity related terms
      pressuregrad_work = length * (-g * 0.5 * (h_left * h_left - hle * hle - (hle + hc) * (zl - zc)) + pressure_flux);

      // Update timestep based on edge i and possibly neighbour n
      // NOTE: We should only change the timestep on the 'first substep'
      // of the timestepping method [substep_count==0]
      if (substep_count == 0)
      {

        // Compute the 'edge-timesteps' (useful for setting flux_update_frequency)
        edge_timestep = radii[k] * 1.0 / fmax(max_speed_local, epsilon);

        // Update the timestep
        if ((tri_full_flag[k] == 1))
        {
          if (max_speed_local > epsilon)
          {
            // Apply CFL condition for triangles joining this edge (triangle k and triangle n)

            // CFL for triangle k

            //local_timestep[0] = fmin(local_timestep[0], edge_timestep);
	          //atomicMin_double(local_timestep, edge_timestep);

            local_timestep = fmin(local_timestep, edge_timestep);

            speed_max_last = fmax(speed_max_last, max_speed_local);
          }
        }
      }

      local_stage_explicit_update = local_stage_explicit_update + edgeflux[0];
      local_xmom_explicit_update  = local_xmom_explicit_update + edgeflux[1];
      local_ymom_explicit_update  = local_ymom_explicit_update + edgeflux[2];

      // If this cell is not a ghost, and the neighbour is a
      // boundary condition OR a ghost cell, then add the flux to the
      // boundary_flux_integral
      if (((n < 0) & (tri_full_flag[k] == 1)) | ((n >= 0) && ((tri_full_flag[k] == 1) & (tri_full_flag[n] == 0))))
      {
        // boundary_flux_sum is an array with length = timestep_fluxcalls
        // For each sub-step, we put the boundary flux sum in.
        //boundary_flux_sum[substep_count] += edgeflux[0];
        local_boundary_flux_sum += edgeflux[0];
        
	      //atomicAdd((boundary_flux_sum+substep_count), edgeflux[0]);

        //printf(" k = %d  substep_count = %ld edge_flux %f bflux %f \n",k,substep_count, edgeflux[0], boundary_flux_sum[substep_count] );

        //printf('boundary_flux_sum_substep %e \n',boundary_flux_sum_substep);
        
        
      }

      local_xmom_explicit_update -= normals[ki2] * pressuregrad_work;
      local_ymom_explicit_update -= normals[ki2 + 1] * pressuregrad_work;

    } // End edge i (and neighbour n)

    // Keep track of maximal speeds
    if (substep_count == 0)
      max_speed[k] = speed_max_last; // max_speed;

    // Normalise triangle k by area and store for when all conserved
    // quantities get updated
    inv_area = 1.0 / areas[k];
    stage_explicit_update[k] = local_stage_explicit_update * inv_area;
    xmom_explicit_update[k]  = local_xmom_explicit_update * inv_area;
    ymom_explicit_update[k]  = local_ymom_explicit_update * inv_area;

    boundary_flux_sum_k_array[k] = local_boundary_flux_sum;
    timestep_k_array[k] = local_timestep;

  } // End triangle k


//  printf("cuda boundary_flux_sum_substep %f \n",boundary_flux_sum[substep_count]);
//  printf("cuda local_timestep            %f \n",local_timestep[0]);

}




// // Computational function for flux computation
// int main(int *argc, char*argv[])
// {
//   // local variables
//   long substep_count;
//   long number_of_elements =1024;
  
//   double limiting_threshold = 10 ;
//   long   low_froude;
//   double g;
//   double epsilon;

//   long ncol_riverwall_hydraulic_properties;
 
//   double local_timestep[1];      // InOut
//   double* boundary_flux_sum ;     // InOut
//   double* max_speed;             // InOut
//   double* stage_explicit_update; // InOut
//   double* xmom_explicit_update; // InOut
//   double* ymom_explicit_update ;// InOut

//   double* stage_centroid_values;
//   double* stage_edge_values;
//   double* xmom_edge_values ;
//   double* ymom_edge_values ;
//   double* bed_edge_values ;
//   double* height_edge_values ;
//   double* height_centroid_values;
//   double* bed_centroid_values ;
//   double* stage_boundary_values ;
//   double* xmom_boundary_values ;
//   double* ymom_boundary_values ;
//   double* areas ;
//   double* normals ;
//   double* edgelengths ;
//   double* radii ;
//   long* tri_full_flag ;
//   long* neighbours ;
//   long* neighbour_edges ;
//   long* edge_flux_type ;
//   long* edge_river_wall_counter ;
//   double* riverwall_elevation ;
//   long* riverwall_rowIndex ;
//   double* riverwall_hydraulic_properties;

//   unsigned int THREADS_PER_BLOCK;

//   long timestep_fluxcalls = 1;
//   long base_call = 1;
//   THREADS_PER_BLOCK = 256;
//   long NO_OF_BLOCKS = number_of_elements/THREADS_PER_BLOCK; 

//   __cuda_compute_fluxes_loop_1<<<NO_OF_BLOCKS,THREADS_PER_BLOCK>>>(local_timestep,        // InOut
//                                boundary_flux_sum,     // InOut
//                                max_speed,             // InOut
//                                stage_explicit_update, // InOut
//                                xmom_explicit_update,  // InOut
//                                ymom_explicit_update,  // InOut

//                                stage_centroid_values,
//                                stage_edge_values,
//                                xmom_edge_values,
//                                ymom_edge_values,
//                                bed_edge_values,
//                                height_edge_values,
//                                height_centroid_values,
//                                bed_centroid_values,
//                                stage_boundary_values,
//                                xmom_boundary_values,
//                                ymom_boundary_values,
//                                areas,
//                                normals,
//                                edgelengths,
//                                radii,
//                                tri_full_flag,
//                                neighbours,
//                                neighbour_edges,
//                                edge_flux_type,
//                                edge_river_wall_counter,
//                                riverwall_elevation,
//                                riverwall_rowIndex,
//                                riverwall_hydraulic_properties,

//                                number_of_elements,
//                                substep_count,
//                                ncol_riverwall_hydraulic_properties,
//                                epsilon,
//                                g,
//                                low_froude,
//                                limiting_threshold);

// }

