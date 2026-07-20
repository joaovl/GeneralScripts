from collections import OrderedDict

import numpy as np
from scipy.interpolate import griddata

_CACHE_MAXSIZE = 4
_CACHE = OrderedDict()


def _build_calibration_grid(pitin, yawin, Pin, Ptotin, Pstatin, ngrid):

    inputs = (pitin, yawin, Pin, Ptotin, Pstatin)
    key = tuple(id(a) for a in inputs) + (ngrid,)
    cached = _CACHE.get(key)
    if cached is not None:
        cached_inputs, result = cached
        if all(a is b for a, b in zip(inputs, cached_inputs)):
            _CACHE.move_to_end(key)
            return result
        del _CACHE[key]

    pitin = np.asarray(pitin, dtype=float)
    yawin = np.asarray(yawin, dtype=float)
    Pin = np.asarray(Pin, dtype=float)
    Ptotin = np.asarray(Ptotin, dtype=float)
    Pstatin = np.asarray(Pstatin, dtype=float)

    n_holes = Pin.shape[1]

    Pmax_cal = Pin.max(axis=1)   # approximate stagnation pressure, per point
    Pbar_cal = Pin.min(axis=1)   # approximate static pressure, per point
    denom_cal = Pmax_cal - Pbar_cal  # difference between max and min


    flat = np.flatnonzero(denom_cal == 0.0)
    if flat.size:
        raise ValueError(
            "calibration rows {} have identical pressure at every hole "
            "(Pmax == Pbar), so they cannot be normalized".format(flat.tolist())
        )

    # This section creates the grid of pitch vs. yaw
    pit_axis = np.linspace(pitin.min(), pitin.max(), ngrid)
    yaw_axis = np.linspace(yawin.min(), yawin.max(), ngrid)
    pit_grid, yaw_grid = np.meshgrid(pit_axis, yaw_axis)

    points = np.column_stack([pitin, yawin])

    hole_grids = np.empty((n_holes, ngrid, ngrid))
    for i in range(n_holes):
        norm_p = (Pmax_cal - Pin[:, i]) / denom_cal
        hole_grids[i] = griddata(points, norm_p, (pit_grid, yaw_grid), method="cubic")

    # eq. (8)-style total/static pressure coefficients, using the true
    # reference pressures (not derived from the holes themselves)
    calCPo = (Pmax_cal - Ptotin) / denom_cal
    calCPs = (Pbar_cal - Pstatin) / denom_cal

    CPo_grid = griddata(points, calCPo, (pit_grid, yaw_grid), method="cubic")
    CPs_grid = griddata(points, calCPs, (pit_grid, yaw_grid), method="cubic")

    result = (pit_grid, yaw_grid, hole_grids, CPo_grid, CPs_grid)
    _CACHE[key] = (inputs, result)
    _CACHE.move_to_end(key)
    while len(_CACHE) > _CACHE_MAXSIZE:
        _CACHE.popitem(last=False)
    return result


def NHoleProcessor(pitin, yawin, Pin, Ptotin, Pstatin, P, Ptot, Pstat, rho, ngrid=101):

    pit_grid, yaw_grid, hole_grids, CPo_grid, CPs_grid = _build_calibration_grid(
        pitin, yawin, Pin, Ptotin, Pstatin, ngrid
    )

    P = np.atleast_2d(np.asarray(P, dtype=float))
    n_meas, n_holes = P.shape

    n_holes_cal = hole_grids.shape[0]
    if n_holes != n_holes_cal:
        raise ValueError(
            "measurement has {} holes but the calibration has {}".format(
                n_holes, n_holes_cal
            )
        )

    # Accept a scalar or length-1 density (the single hardcoded 1.225 that
    # dashboard.py passes) as well as one density per measurement row.
    rho = np.atleast_1d(np.asarray(rho, dtype=float))
    if rho.size == 1:
        rho = np.repeat(rho, n_meas)
    elif rho.size != n_meas:
        raise ValueError(
            "rho has {} entries but there are {} measurements".format(
                rho.size, n_meas
            )
        )

    Pmax = P.max(axis=1)
    Pbar = P.min(axis=1)
    denom = Pmax - Pbar

    aoa = np.empty(n_meas)
    yaw = np.empty(n_meas)
    airspeed = np.empty(n_meas)
    err = np.empty(n_meas)

    for ix in range(n_meas):

        # Every hole reading identical: no flow direction to recover, and the
        # normalization below would be 0/0. Happens at rest, and on a stuck or
        # fully blocked probe.
        if denom[ix] == 0.0:
            aoa[ix] = np.nan
            yaw[ix] = np.nan
            airspeed[ix] = np.nan
            err[ix] = np.inf
            continue


        perr = np.zeros((ngrid, ngrid))
        for i in range(n_holes):
            norm_p = (Pmax[ix] - P[ix, i]) / denom[ix]
            perr += (norm_p - hole_grids[i]) ** 2

        if np.all(np.isnan(perr)):
            aoa[ix] = np.nan
            yaw[ix] = np.nan
            airspeed[ix] = np.nan
            err[ix] = np.inf
            continue

        mini = np.unravel_index(np.nanargmin(perr), perr.shape)
        min_err = perr[mini]

        aoa[ix] = pit_grid[mini]
        yaw[ix] = yaw_grid[mini]
        CP0 = CPo_grid[mini]
        CPS = CPs_grid[mini]

        err[ix] = np.sqrt(min_err / n_holes)

        # eq. (10)/(11): (P0 - PS) = denom * (CPS - CP0 + 1), which by
        # Bernoulli is exactly the dynamic pressure.
        dynamic_pressure = denom[ix] * (CPS - CP0 + 1.0)
        dynamic_pressure = max(dynamic_pressure, 0.0)  # guard against noise
        airspeed[ix] = np.sqrt(2.0 * dynamic_pressure / rho[ix])

    return aoa, yaw, airspeed, err
