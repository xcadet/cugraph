import time

from dask.distributed import Client
from dask_cuda import LocalCUDACluster as CUDACluster

# Maximal number of verifications of the number of workers
DEFAULT_MAX_ATTEMPT = 100

# Time betweenness each attempt in seconds
DEFAULT_WAIT_TIME = 0.5


class OPGContext:
    """Utility Context Manager to start a multi GPU context using dask_cuda

    Parameters:
    -----------

    number_of_devices : int
        Number of devices to use, verification must be done prior to call
        to ensure that there are enough devices available.
    """
    def __init__(self, number_of_devices):
        self._number_of_devices = number_of_devices
        self._cluster = None
        self._client = None

    @property
    def client(self):
        return self._client

    @property
    def cluster(self):
        return self._cluster

    def __enter__(self):
        self._prepare_opg()
        return self

    def _prepare_opg(self):
        self._prepare_cluster()
        self._prepare_client()

    def _prepare_cluster(self):
        self._cluster = CUDACluster(
            n_workers=self._number_of_devices,
        )

    def _prepare_client(self):
        self._client = Client(self._cluster)
        self._client.wait_for_workers(self._number_of_devices)

    def _close(self):
        if self._client is not None:
            self._client.close()
        if self._cluster is not None:
            self._cluster.close()

    def __exit__(self, type, value, traceback):
        self._close()


# NOTE: This only looks for the number of  workers
# Tries to rescale the given cluster and wait until all workers are ready
# or until the maximal number of attempts is reached
def enforce_rescale(cluster, scale, max_attempts=DEFAULT_MAX_ATTEMPT,
                    wait_time=DEFAULT_WAIT_TIME):
    cluster.scale(scale)
    attempt = 0
    ready = (len(cluster.workers) == scale)
    while (attempt < max_attempts) and not ready:
        time.sleep(wait_time)
        ready = (len(cluster.workers) == scale)
        attempt += 1
    assert ready, "Unable to rescale cluster to {}".format(scale)