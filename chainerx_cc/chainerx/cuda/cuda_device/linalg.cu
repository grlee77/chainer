#include "chainerx/cuda/cuda_device.h"

#include <cstdint>
#include <mutex>
#include <type_traits>

#include <cublas_v2.h>
#include <cuda_runtime.h>
#include <cusolverDn.h>
#include <cuda_fp16.hpp>

#include "chainerx/array.h"
#include "chainerx/axes.h"
#include "chainerx/backend.h"
#include "chainerx/backend_util.h"
#include "chainerx/cuda/cublas.h"
#include "chainerx/cuda/cuda_runtime.h"
#include "chainerx/cuda/cuda_set_device_scope.h"
#include "chainerx/cuda/cusolver.h"
#include "chainerx/cuda/data_type.cuh"
#include "chainerx/cuda/float16.cuh"
#include "chainerx/cuda/kernel_regist.h"
#include "chainerx/device.h"
#include "chainerx/dtype.h"
#include "chainerx/error.h"
#include "chainerx/float16.h"
#include "chainerx/kernels/creation.h"
#include "chainerx/kernels/linalg.h"
#include "chainerx/kernels/misc.h"
#include "chainerx/macro.h"
#include "chainerx/native/native_device.h"
#include "chainerx/routines/creation.h"
#include "chainerx/routines/linalg.h"

namespace chainerx {
namespace cuda {
namespace {

template <typename T>
cusolverStatus_t GetrfBuffersize(cusolverDnHandle_t /*handle*/, int /*m*/, int /*n*/, T* /*a*/, int /*lda*/, int* /*lwork*/) {
    throw DtypeError{"Only Arrays of float or double type are supported by getrf (LU)"};
}

template <typename T>
cusolverStatus_t Getrf(
        cusolverDnHandle_t /*handle*/, int /*m*/, int /*n*/, T* /*a*/, int /*lda*/, T* /*workspace*/, int* /*devipiv*/, int* /*devinfo*/) {
    throw DtypeError{"Only Arrays of float or double type are supported by getrf (LU)"};
}

template <typename T>
cusolverStatus_t Getrs(
        cusolverDnHandle_t /*handle*/,
        cublasOperation_t /*trans*/,
        int /*n*/,
        int /*nrhs*/,
        T* /*a*/,
        int /*lda*/,
        int* /*devipiv*/,
        T* /*b*/,
        int /*ldb*/,
        int* /*devinfo*/) {
    throw DtypeError{"Only Arrays of float or double type are supported by getrs (Solve)"};
}

template <typename T>
cusolverStatus_t PotrfBuffersize(
        cusolverDnHandle_t /*handle*/, cublasFillMode_t /*uplo*/, int /*n*/, T* /*a*/, int /*lda*/, int* /*lwork*/) {
    throw DtypeError{"Only Arrays of float or double type are supported by potrf (Cholesky)"};
}

template <typename T>
cusolverStatus_t Potrf(
        cusolverDnHandle_t /*handle*/,
        cublasFillMode_t /*uplo*/,
        int /*n*/,
        T* /*a*/,
        int /*lda*/,
        T* /*workspace*/,
        int /*lwork*/,
        int* /*devinfo*/) {
    throw DtypeError{"Only Arrays of float or double type are supported by potrf (Cholesky)"};
}

template <>
cusolverStatus_t GetrfBuffersize<double>(cusolverDnHandle_t handle, int m, int n, double* a, int lda, int* lwork) {
    return cusolverDnDgetrf_bufferSize(handle, m, n, a, lda, lwork);
}

template <>
cusolverStatus_t GetrfBuffersize<float>(cusolverDnHandle_t handle, int m, int n, float* a, int lda, int* lwork) {
    return cusolverDnSgetrf_bufferSize(handle, m, n, a, lda, lwork);
}

template <>
cusolverStatus_t Getrf<double>(cusolverDnHandle_t handle, int m, int n, double* a, int lda, double* workspace, int* devipiv, int* devinfo) {
    return cusolverDnDgetrf(handle, m, n, a, lda, workspace, devipiv, devinfo);
}

template <>
cusolverStatus_t Getrf<float>(cusolverDnHandle_t handle, int m, int n, float* a, int lda, float* workspace, int* devipiv, int* devinfo) {
    return cusolverDnSgetrf(handle, m, n, a, lda, workspace, devipiv, devinfo);
}

template <>
cusolverStatus_t Getrs<double>(
        cusolverDnHandle_t handle,
        cublasOperation_t trans,
        int n,
        int nrhs,
        double* a,
        int lda,
        int* devipiv,
        double* b,
        int ldb,
        int* devinfo) {
    return cusolverDnDgetrs(handle, trans, n, nrhs, a, lda, devipiv, b, ldb, devinfo);
}

template <>
cusolverStatus_t Getrs<float>(
        cusolverDnHandle_t handle,
        cublasOperation_t trans,
        int n,
        int nrhs,
        float* a,
        int lda,
        int* devipiv,
        float* b,
        int ldb,
        int* devinfo) {
    return cusolverDnSgetrs(handle, trans, n, nrhs, a, lda, devipiv, b, ldb, devinfo);
}

template <>
cusolverStatus_t PotrfBuffersize<double>(cusolverDnHandle_t handle, cublasFillMode_t uplo, int n, double* a, int lda, int* lwork) {
    return cusolverDnDpotrf_bufferSize(handle, uplo, n, a, lda, lwork);
}

template <>
cusolverStatus_t PotrfBuffersize<float>(cusolverDnHandle_t handle, cublasFillMode_t uplo, int n, float* a, int lda, int* lwork) {
    return cusolverDnSpotrf_bufferSize(handle, uplo, n, a, lda, lwork);
}

template <>
cusolverStatus_t Potrf<double>(
        cusolverDnHandle_t handle, cublasFillMode_t uplo, int n, double* a, int lda, double* workspace, int lwork, int* devinfo) {
    return cusolverDnDpotrf(handle, uplo, n, a, lda, workspace, lwork, devinfo);
}

template <>
cusolverStatus_t Potrf<float>(
        cusolverDnHandle_t handle, cublasFillMode_t uplo, int n, float* a, int lda, float* workspace, int lwork, int* devinfo) {
    return cusolverDnSpotrf(handle, uplo, n, a, lda, workspace, lwork, devinfo);
}

template <typename T>
void SolveImpl(const Array& a, const Array& b, const Array& out) {
    Device& device = a.device();
    Dtype dtype = a.dtype();

    cuda_internal::DeviceInternals& device_internals = cuda_internal::GetDeviceInternals(static_cast<CudaDevice&>(device));

    Array lu_matrix = Empty(a.shape(), dtype, device);
    device.backend().CallKernel<CopyKernel>(a.Transpose(), lu_matrix);
    auto lu_ptr = static_cast<T*>(internal::GetRawOffsetData(lu_matrix));

    int64_t m = a.shape()[0];
    int64_t nrhs = 1;
    if (b.ndim() == 2) {
        nrhs = b.shape()[1];
    }

    Array ipiv = Empty(Shape{m}, Dtype::kInt32, device);
    auto ipiv_ptr = static_cast<int*>(internal::GetRawOffsetData(ipiv));

    int buffersize = 0;
    device_internals.cusolverdn_handle().Call(GetrfBuffersize<T>, m, m, lu_ptr, m, &buffersize);

    Array work = Empty(Shape{buffersize}, dtype, device);
    auto work_ptr = static_cast<T*>(internal::GetRawOffsetData(work));

    std::shared_ptr<void> devinfo = device.Allocate(sizeof(int));

    device_internals.cusolverdn_handle().Call(Getrf<T>, m, m, lu_ptr, m, work_ptr, ipiv_ptr, static_cast<int*>(devinfo.get()));

    int devinfo_h = 0;
    Device& native_device = GetDefaultContext().GetDevice({"native", 0});
    device.MemoryCopyTo(&devinfo_h, devinfo.get(), sizeof(int), native_device);
    if (devinfo_h != 0) {
        throw ChainerxError{"Unsuccessful getrf (LU) execution. Info = ", devinfo_h};
    }

    Array out_transposed = b.Transpose().Copy();
    auto out_ptr = static_cast<T*>(internal::GetRawOffsetData(out_transposed));

    device_internals.cusolverdn_handle().Call(
            Getrs<T>, CUBLAS_OP_N, m, nrhs, lu_ptr, m, ipiv_ptr, out_ptr, m, static_cast<int*>(devinfo.get()));

    device.MemoryCopyTo(&devinfo_h, devinfo.get(), sizeof(int), native_device);
    if (devinfo_h != 0) {
        throw ChainerxError{"Unsuccessful getrs (Solve) execution. Info = ", devinfo_h};
    }

    device.backend().CallKernel<CopyKernel>(out_transposed.Transpose(), out);
}

}  // namespace

class CudaSolveKernel : public SolveKernel {
public:
    void Call(const Array& a, const Array& b, const Array& out) override {
        Device& device = a.device();
        Dtype dtype = a.dtype();
        CudaSetDeviceScope scope{device.index()};

        CHAINERX_ASSERT(a.ndim() == 2);
        CHAINERX_ASSERT(a.shape()[0] == a.shape()[1]);

        VisitFloatingPointDtype(dtype, [&](auto pt) {
            using T = typename decltype(pt)::type;
            SolveImpl<T>(a, b, out);
        });
    }
};

CHAINERX_CUDA_REGISTER_KERNEL(SolveKernel, CudaSolveKernel);

class CudaInverseKernel : public InverseKernel {
public:
    void Call(const Array& a, const Array& out) override {
        Device& device = a.device();
        Dtype dtype = a.dtype();
        CudaSetDeviceScope scope{device.index()};

        CHAINERX_ASSERT(a.ndim() == 2);
        CHAINERX_ASSERT(a.shape()[0] == a.shape()[1]);

        // There is LAPACK routine ``getri`` for computing the inverse of an LU-factored matrix,
        // but cuSOLVER does not have it implemented, therefore inverse is obtained with ``getrs``
        // inv(A) == solve(A, Identity)
        Array b = Identity(a.shape()[0], dtype, device);
        device.backend().CallKernel<SolveKernel>(a, b, out);
    }
};

CHAINERX_CUDA_REGISTER_KERNEL(InverseKernel, CudaInverseKernel);

class CudaCholeskyKernel : public CholeskyKernel {
public:
    void Call(const Array& a, const Array& out) override {
        Device& device = a.device();
        device.CheckDevicesCompatible(a, out);
        Dtype dtype = a.dtype();
        CudaSetDeviceScope scope{device.index()};

        CHAINERX_ASSERT(a.ndim() == 2);
        CHAINERX_ASSERT(out.ndim() == 2);
        CHAINERX_ASSERT(a.shape()[0] == a.shape()[1]);

        // potrf (cholesky) stores result in-place, therefore copy ``a`` to ``out`` and then pass ``out`` to the routine
        device.backend().CallKernel<CopyKernel>(Tril(a, 0), out);

        Array out_contiguous = AsContiguous(out);

        auto cholesky_impl = [&](auto pt) {
            CHAINERX_ASSERT(a.dtype() == out_contiguous.dtype());

            using T = typename decltype(pt)::type;

            // Note that cuSOLVER uses Fortran order.
            // To compute a lower triangular matrix L = cholesky(A), we use cuSOLVER to compute an upper triangular matrix U = cholesky(A).
            cublasFillMode_t uplo = CUBLAS_FILL_MODE_UPPER;

            cuda_internal::DeviceInternals& device_internals = cuda_internal::GetDeviceInternals(static_cast<CudaDevice&>(device));

            // compute workspace size and prepare workspace
            auto out_ptr = static_cast<T*>(internal::GetRawOffsetData(out_contiguous));
            int work_size = 0;
            int64_t N = a.shape()[0];
            device_internals.cusolverdn_handle().Call(PotrfBuffersize<T>, uplo, N, out_ptr, N, &work_size);

            // POTRF execution
            Array work = Empty(Shape({work_size}), dtype, device);
            auto work_ptr = static_cast<T*>(internal::GetRawOffsetData(work));

            std::shared_ptr<void> devInfo = device.Allocate(sizeof(int));
            device_internals.cusolverdn_handle().Call(Potrf<T>, uplo, N, out_ptr, N, work_ptr, work_size, static_cast<int*>(devInfo.get()));

            int devInfo_h = 0;
            Device& native_device = GetDefaultContext().GetDevice({"native", 0});
            device.MemoryCopyTo(&devInfo_h, devInfo.get(), sizeof(int), native_device);
            if (devInfo_h != 0) {
                throw ChainerxError{"Unsuccessful potrf (Cholesky) execution. Info = ", devInfo_h};
            }
        };

        VisitFloatingPointDtype(dtype, cholesky_impl);
    }
};

CHAINERX_CUDA_REGISTER_KERNEL(CholeskyKernel, CudaCholeskyKernel);

}  // namespace cuda
}  // namespace chainerx
