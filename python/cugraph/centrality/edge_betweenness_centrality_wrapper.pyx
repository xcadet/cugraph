# Copyright (c) 2020, NVIDIA CORPORATION.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# cython: profile=False
# distutils: language = c++
# cython: embedsignature = True
# cython: language_level = 3

from cugraph.centrality.betweenness_centrality cimport edge_betweenness_centrality as c_edge_betweenness_centrality
from cugraph.structure.graph_new cimport *
from cugraph.utilities.unrenumber import unrenumber
from libcpp cimport bool
from libc.stdint cimport uintptr_t
from libc.stdlib cimport calloc, malloc, free
from cugraph.structure import graph_new_wrapper
from cugraph.structure.graph import DiGraph, Graph
import cudf
import rmm
import numpy as np
import numpy.ctypeslib as ctypeslib


def edge_betweenness_centrality(input_graph, normalized, weight, k,
                                vertices, result_dtype):
    """
    Call betweenness centrality
    """
    # NOTE: This is based on the fact that the call to the wrapper already
    #       checked for the validity of the implementation parameter
    cdef GraphCSRView[int, int, float] graph_float
    cdef GraphCSRView[int, int, double] graph_double

    if not input_graph.adjlist:
        input_graph.view_adj_list()

    [offsets, indices] = graph_new_wrapper.datatype_cast([input_graph.adjlist.offsets, input_graph.adjlist.indices], [np.int32])

    number_of_vertices= input_graph.number_of_vertices()
    number_of_edges = len(indices)

    df = cudf.DataFrame()
    df['src'] = cudf.Series(np.zeros(number_of_edges, dtype=np.int32))
    df['dst'] = indices.copy()
    df['betweenness_centrality'] = cudf.Series(np.zeros(number_of_edges,
                                               dtype=result_dtype))

    cdef uintptr_t c_src_identifier = df['src'].__cuda_array_interface__['data'][0]
    cdef uintptr_t c_dst_identifier = df['dst'].__cuda_array_interface__['data'][0]
    cdef uintptr_t c_betweenness = df['betweenness_centrality'].__cuda_array_interface__['data'][0]

    cdef uintptr_t c_offsets = offsets.__cuda_array_interface__['data'][0]
    cdef uintptr_t c_indices = indices.__cuda_array_interface__['data'][0]
    cdef uintptr_t c_weight = <uintptr_t> NULL
    cdef uintptr_t c_vertices = <uintptr_t> NULL

    if weight is not None:
        c_weight = weight.__cuda_array_interface__['data'][0]

    # FIXME: We could sample directly from a cudf array in the futur: i.e
    #       c_vertices = vertices.__cuda_array_interface__['data'][0]
    if vertices is not None:
        c_vertices = np.array(vertices, dtype=np.int32).__array_interface__['data'][0]

    c_k = 0
    if k is not None:
        c_k = k

    # NOTE: The current implementation only has <int, int, float, float> and
    #       <int, int, double, double> as explicit template declaration
    #       The current BFS requires the GraphCSR to be declared
    #       as <int, int, float> or <int, int double> even if weights is null
    if result_dtype == np.float32:
        graph_float = GraphCSRView[int, int, float](<int*> c_offsets,
                                                    <int*> c_indices,
                                                    <float*> NULL,
                                                    number_of_vertices,
                                                    number_of_edges)
        # fixme: there might be a way to avoid manually setting the graph property
        graph_float.prop.directed = type(input_graph) is DiGraph

        c_edge_betweenness_centrality[int, int,
                                      float, float](graph_float,
                                                    <float*> c_betweenness,
                                                    normalized,
                                                    <float*> c_weight,
                                                    c_k,
                                                    <int*> c_vertices)
        graph_float.get_source_indices(<int*>c_src_identifier)
    elif result_dtype == np.float64:
        graph_double = GraphCSRView[int, int, double](<int*>c_offsets,
                                                      <int*>c_indices,
                                                      <double*> NULL,
                                                      number_of_vertices,
                                                      number_of_edges)
        # FIXME: there might be a way to avoid manually setting
        #        the graph property
        graph_double.prop.directed = type(input_graph) is DiGraph

        c_edge_betweenness_centrality[int, int,
                                      double, double](graph_double,
                                                      <double*> c_betweenness,
                                                      normalized,
                                                      <double*> c_weight,
                                                      c_k,
                                                      <int*> c_vertices)
        graph_double.get_source_indices(<int*>c_src_identifier)
    else:
        raise TypeError("result type for betweenness centrality can only be "
                        "float or double")

    # FIXME: For large graph renumbering produces a dataframe organized
    #       in buckets, i.e, if they are 3 buckets
    # 0
    # 8191
    # 16382
    # 1
    # 8192 ...
    # Instead of having  the sources in ascending order
    if input_graph.renumbered:
        df = unrenumber(input_graph.edgelist.renumber_map, df, 'src')
        df = unrenumber(input_graph.edgelist.renumber_map, df, 'dst')

    if type(input_graph) is Graph:
        lower_triangle = df['src'] >= df['dst']
        df[["src", "dst"]][lower_triangle] = df[["dst", "src"]][lower_triangle]
        df = df.groupby(by=["src", "dst"]).sum().reset_index()

    return df