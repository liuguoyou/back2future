#include "utils.h"
// Bilinear sampling is done in BHWD (coalescing is not obvious in BDHW)
// we assume BHWD format in inputImages
// we assume BHW(YX) format on grids

__device__ void getTopLeft(float x, int xOut, int width, int& point, float& weight)
{
   /* for interpolation :
      stores in point and weight :
      - the x-coordinate of the pixel on the left (or y-coordinate of the upper pixel)
      - the weight for interpolating
   */

   //float xcoord = (x + 1) * (width - 1) / 2;
   float xcoord = x + xOut;
   if (xcoord < 0) { xcoord = 0; }
   if (xcoord > (width-1) ) { xcoord = width -1; }
   point = floor(xcoord);
   weight = 1 - (xcoord - point);
}

__device__ bool between(int value, int lowerBound, int upperBound)
{
   return (value >= lowerBound && value <= upperBound);
}

__device__ void sumReduceShMem(volatile float s[])
{
   /* obviously only works for 32 elements */
   /* sums up a shared memory array of 32 elements, stores it in s[0] */
   /* whole warp can then read first element (broadcasting) */
   if(threadIdx.x<16) { s[threadIdx.x] = s[threadIdx.x] + s[threadIdx.x+16]; }
   if(threadIdx.x<8) { s[threadIdx.x] = s[threadIdx.x] + s[threadIdx.x+8]; }
   if(threadIdx.x<4) { s[threadIdx.x] = s[threadIdx.x] + s[threadIdx.x+4]; }
   if(threadIdx.x<2) { s[threadIdx.x] = s[threadIdx.x] + s[threadIdx.x+2]; }
   if(threadIdx.x<1) { s[threadIdx.x] = s[threadIdx.x] + s[threadIdx.x+1]; }
}



__global__ void bilinearSamplingFromGrid(float* inputImages_data, int inputImages_strideBatch, int inputImages_strideChannels, int inputImages_strideHeight, int inputImages_strideWidth,
                                         float* grids_data, int grids_strideBatch, int grids_strideYX, int grids_strideHeight, int grids_strideWidth,
                                         float* output_data, int output_strideBatch, int output_strideChannels, int output_strideHeight, int output_strideWidth,
                                         int inputImages_channels, int inputImages_height, int inputImages_width, int output_width)
{
   // each (32,16) block 16 output pixels (for coalescing the grid read)
   // x,y = coordinates (xOut = blockIdx.x*16+blockDim.y+threadIdx.y)
   // z = batch index
   // threadIdx.x : used for features (coalescing is trivial)
      
   const int xOut = blockIdx.x*blockDim.y+threadIdx.y;
   const bool withinImageBounds = xOut < output_width;
   const bool withinGridBounds = blockIdx.x*blockDim.y + threadIdx.x / 2 < output_width;
   const int yOut = blockIdx.y;
   const int width = inputImages_width;
   const int height = inputImages_height;
   
   const int b = blockIdx.z;
   
   float yf,xf;

   __shared__ float gridData[32];
   if (threadIdx.y==0 && withinGridBounds)
   {
      gridData[threadIdx.x] = grids_data[b*grids_strideBatch + yOut*grids_strideHeight + xOut*grids_strideWidth + threadIdx.x];
   }
   __syncthreads();
   if(!withinImageBounds) return;
   xf = gridData[threadIdx.y*2];
   yf = gridData[threadIdx.y*2+1];
   
   int yInTopLeft, xInTopLeft;
   float yWeightTopLeft, xWeightTopLeft;
   
   getTopLeft(xf, xOut, inputImages_width, xInTopLeft, xWeightTopLeft);
   getTopLeft(yf, yOut, inputImages_height, yInTopLeft, yWeightTopLeft);
   
   //getTopLeft(xf, inputImages_width, xInTopLeft, xWeightTopLeft);
   //getTopLeft(yf, inputImages_height, yInTopLeft, yWeightTopLeft);
   
   const int outAddress = output_strideBatch * b + output_strideHeight * yOut + output_strideWidth * xOut;
   const int inAddress = inputImages_strideBatch * b + inputImages_strideHeight * yOut + inputImages_strideWidth * xOut;
   const int inTopLeftAddress = inputImages_strideBatch * b + inputImages_strideHeight * yInTopLeft + inputImages_strideWidth * xInTopLeft;
   const int inTopRightAddress = inTopLeftAddress + inputImages_strideWidth;
   const int inBottomLeftAddress = inTopLeftAddress + inputImages_strideHeight;
   const int inBottomRightAddress = inBottomLeftAddress + inputImages_strideWidth;

   float v=0;
   float inTopLeft=0;
   float inTopRight=0;
   float inBottomLeft=0;
   float inBottomRight=0;

   bool topLeftIsIn = between(xInTopLeft, 0, width-1) && between(yInTopLeft, 0, height-1);
   bool topRightIsIn = between(xInTopLeft+1, 0, width-1) && between(yInTopLeft, 0, height-1);
   bool bottomLeftIsIn = between(xInTopLeft, 0, width-1) && between(yInTopLeft+1, 0, height-1);
   bool bottomRightIsIn = between(xInTopLeft+1, 0, width-1) && between(yInTopLeft+1, 0, height-1);

   // interpolation happens here
   for(int t=threadIdx.x; t<inputImages_channels; t+= blockDim.x)
   {
      if(topLeftIsIn) inTopLeft = inputImages_data[inTopLeftAddress + t];
      if(topRightIsIn) inTopRight = inputImages_data[inTopRightAddress + t];
      if(bottomLeftIsIn) inBottomLeft = inputImages_data[inBottomLeftAddress + t];
      if(bottomRightIsIn) inBottomRight = inputImages_data[inBottomRightAddress + t];

      v = xWeightTopLeft * yWeightTopLeft * inTopLeft
        + (1 - xWeightTopLeft) * yWeightTopLeft * inTopRight
        + xWeightTopLeft * (1 - yWeightTopLeft) * inBottomLeft
        + (1 - xWeightTopLeft) * (1 - yWeightTopLeft) * inBottomRight;
      
      //v = inBottomRight;
      output_data[outAddress + t] = v;
   }
}


static int cunn_BilinearSamplerBHWD_updateOutput(lua_State *L)
{
  THCState *state = getCutorchState(L);
  THCudaTensor *inputImages = (THCudaTensor *)luaT_checkudata(L, 2, "torch.CudaTensor");
  THCudaTensor *grids = (THCudaTensor *)luaT_checkudata(L, 3, "torch.CudaTensor");
  THCudaTensor *output = (THCudaTensor *)luaT_checkudata(L, 4, "torch.CudaTensor");


   dim3 blocks((output->size[2]+15)/16, output->size[1], output->size[0]);
   dim3 threads(32,16);

   /* assume BHWD */
   bilinearSamplingFromGrid <<< blocks, threads, 0, THCState_getCurrentStream(state) >>> (THCudaTensor_data(state, inputImages), 
                                                      THCudaTensor_stride(state, inputImages, 0), 
                                                      THCudaTensor_stride(state, inputImages, 3), 
                                                      THCudaTensor_stride(state, inputImages, 1), 
                                                      THCudaTensor_stride(state, inputImages, 2),
                                                      THCudaTensor_data(state, grids),  
                                                      THCudaTensor_stride(state, grids, 0), 
                                                      THCudaTensor_stride(state, grids, 3),
                                                      THCudaTensor_stride(state, grids, 1), 
                                                      THCudaTensor_stride(state, grids, 2),
                                                      THCudaTensor_data(state, output),  
                                                      THCudaTensor_stride(state, output, 0), 
                                                      THCudaTensor_stride(state, output, 3),
                                                      THCudaTensor_stride(state, output, 1), 
                                                      THCudaTensor_stride(state, output, 2),
                                                      THCudaTensor_size(state, inputImages, 3),
                                                      THCudaTensor_size(state, inputImages, 1), 
                                                      THCudaTensor_size(state, inputImages, 2),
                                                      THCudaTensor_size(state, output, 2));


  // check for errors
  cudaError_t err = cudaGetLastError();
  if (err != cudaSuccess) {
    printf("error in BilinearSampler.updateOutput: %s\n", cudaGetErrorString(err));
    THError("aborting");
  }
  return 1;
}


template<bool onlyGrid> __global__ void backwardBilinearSampling(float* inputImages_data, int inputImages_strideBatch, int inputImages_strideChannels, int inputImages_strideHeight, int inputImages_strideWidth,
                                         float* gradInputImages_data, int gradInputImages_strideBatch, int gradInputImages_strideChannels, int gradInputImages_strideHeight, int gradInputImages_strideWidth,
                                         float* grids_data, int grids_strideBatch, int grids_strideYX, int grids_strideHeight, int grids_strideWidth,
                                         float* gradGrids_data, int gradGrids_strideBatch, int gradGrids_strideYX, int gradGrids_strideHeight, int gradGrids_strideWidth,
                                         float* gradOutput_data, int gradOutput_strideBatch, int gradOutput_strideChannels, int gradOutput_strideHeight, int gradOutput_strideWidth,
                                         int inputImages_channels, int inputImages_height, int inputImages_width, int gradOutput_width)
{
   // each (32,16) block 16 output pixels (for coalescing the grid read)
   // x,y = coordinates
   // z = batch index
   // threads : used for features
      
   const int xOut = blockIdx.x*blockDim.y+threadIdx.y;
   const bool withinImageBounds = xOut < gradOutput_width;
   const bool withinGridBounds = blockIdx.x*blockDim.y + threadIdx.x / 2 < gradOutput_width;

   const int yOut = blockIdx.y;
   const int width = inputImages_width;
   const int height = inputImages_height;
   
   const int b = blockIdx.z;
   
   float yf,xf;

   __shared__ float gridData[32];
   if (threadIdx.y==0 && withinGridBounds)
   {
      gridData[threadIdx.x] = grids_data[b*grids_strideBatch + yOut*grids_strideHeight + xOut*grids_strideWidth + threadIdx.x];
   }
   __syncthreads();

   if(withinImageBounds)
   {
      xf = gridData[threadIdx.y*2];
      yf = gridData[threadIdx.y*2+1];
      

      
      int yInTopLeft, xInTopLeft;
      float yWeightTopLeft, xWeightTopLeft;
      getTopLeft(xf, xOut, inputImages_width, xInTopLeft, xWeightTopLeft);
      getTopLeft(yf, yOut, inputImages_height, yInTopLeft, yWeightTopLeft);
      
      const int inTopLeftAddress = inputImages_strideBatch * b + inputImages_strideHeight * yInTopLeft + inputImages_strideWidth * xInTopLeft;
      const int inTopRightAddress = inTopLeftAddress + inputImages_strideWidth;
      const int inBottomLeftAddress = inTopLeftAddress + inputImages_strideHeight;
      const int inBottomRightAddress = inBottomLeftAddress + inputImages_strideWidth;

      const int gradInputImagesTopLeftAddress = gradInputImages_strideBatch * b + gradInputImages_strideHeight * yInTopLeft + gradInputImages_strideWidth * xInTopLeft;
      const int gradInputImagesTopRightAddress = gradInputImagesTopLeftAddress + gradInputImages_strideWidth;
      const int gradInputImagesBottomLeftAddress = gradInputImagesTopLeftAddress + gradInputImages_strideHeight;
      const int gradInputImagesBottomRightAddress = gradInputImagesBottomLeftAddress + gradInputImages_strideWidth;

      const int gradOutputAddress = gradOutput_strideBatch * b + gradOutput_strideHeight * yOut + gradOutput_strideWidth * xOut;

      float topLeftDotProduct = 0;
      float topRightDotProduct = 0;
      float bottomLeftDotProduct = 0;
      float bottomRightDotProduct = 0;

      bool topLeftIsIn = between(xInTopLeft, 0, width-1) && between(yInTopLeft, 0, height-1);
      bool topRightIsIn = between(xInTopLeft+1, 0, width-1) && between(yInTopLeft, 0, height-1);
      bool bottomLeftIsIn = between(xInTopLeft, 0, width-1) && between(yInTopLeft+1, 0, height-1);
      bool bottomRightIsIn = between(xInTopLeft+1, 0, width-1) && between(yInTopLeft+1, 0, height-1);

      /*
         In that loop we accumulate
         - gradients into the gradInputImages array with atomic adds
         - we compute the dot product that we need for the grid gradient
      */

      for(int t=threadIdx.x; t<inputImages_channels; t+= blockDim.x)
      {
         float gradOutValue = gradOutput_data[gradOutputAddress + t];
         // bool between(int value, int lowerBound, int upperBound)
         if(topLeftIsIn)
         {
            float inTopLeft = inputImages_data[inTopLeftAddress + t];
            topLeftDotProduct += inTopLeft * gradOutValue;
            if(!onlyGrid) atomicAdd(&gradInputImages_data[gradInputImagesTopLeftAddress + t], xWeightTopLeft * yWeightTopLeft * gradOutValue);
         }

         if(topRightIsIn)
         {
            float inTopRight = inputImages_data[inTopRightAddress + t];
            topRightDotProduct += inTopRight * gradOutValue;
            if(!onlyGrid) atomicAdd(&gradInputImages_data[gradInputImagesTopRightAddress + t], (1 - xWeightTopLeft) * yWeightTopLeft * gradOutValue);
         }

         if(bottomLeftIsIn)
         {
            float inBottomLeft = inputImages_data[inBottomLeftAddress + t];
            bottomLeftDotProduct += inBottomLeft * gradOutValue;
            if(!onlyGrid) atomicAdd(&gradInputImages_data[gradInputImagesBottomLeftAddress + t], xWeightTopLeft * (1 - yWeightTopLeft) * gradOutValue);
         }

         if(bottomRightIsIn)
         {
            float inBottomRight = inputImages_data[inBottomRightAddress + t];
            bottomRightDotProduct += inBottomRight * gradOutValue;
            if(!onlyGrid) atomicAdd(&gradInputImages_data[gradInputImagesBottomRightAddress + t], (1 - xWeightTopLeft) * (1 - yWeightTopLeft) * gradOutValue);
         }
      }
   
      /*
          Here we reduce the dot product and compute the grid gradient before writing it.
       */

       /* could do shuffles and use no shmem at all but cuda arch is 2.0 */
       __shared__ volatile float __shmem[16][32];
       __shmem[threadIdx.y][threadIdx.x] = topLeftDotProduct;
       sumReduceShMem(__shmem[threadIdx.y]);
       topLeftDotProduct = __shmem[threadIdx.y][0];

       __shmem[threadIdx.y][threadIdx.x] = topRightDotProduct;
       sumReduceShMem(__shmem[threadIdx.y]);
       topRightDotProduct = __shmem[threadIdx.y][0];

       __shmem[threadIdx.y][threadIdx.x] = bottomLeftDotProduct;
       sumReduceShMem(__shmem[threadIdx.y]);
       bottomLeftDotProduct = __shmem[threadIdx.y][0];

       __shmem[threadIdx.y][threadIdx.x] = bottomRightDotProduct;
       sumReduceShMem(__shmem[threadIdx.y]);
       bottomRightDotProduct = __shmem[threadIdx.y][0];

       yf = - xWeightTopLeft * topLeftDotProduct + xWeightTopLeft * bottomLeftDotProduct - (1-xWeightTopLeft) * topRightDotProduct + (1-xWeightTopLeft) * bottomRightDotProduct;
       xf = - yWeightTopLeft * topLeftDotProduct + yWeightTopLeft * topRightDotProduct - (1-yWeightTopLeft) * bottomLeftDotProduct + (1-yWeightTopLeft) * bottomRightDotProduct;

       if(threadIdx.x==0)
       {
//          gridData[threadIdx.y*2] = yf * (inputImages_height-1) / 2;
//          gridData[threadIdx.y*2+1] = xf * (inputImages_width-1) / 2;
          gridData[threadIdx.y*2] = xf;
          gridData[threadIdx.y*2+1] = yf;
       }
   }// must put a big if condition in order not to hang at __syncthreads()...
   __syncthreads();

   if(threadIdx.y==0 && withinGridBounds)      
        gradGrids_data[b*gradGrids_strideBatch + yOut*gradGrids_strideHeight + xOut*gradGrids_strideWidth + threadIdx.x] = gridData[threadIdx.x];   

//   __syncthreads();

//  if(threadIdx.y==0 && withinGridBounds)      
//       gradGrids_data[b*gradGrids_strideBatch + yOut*gradGrids_strideHeight + xOut*gradGrids_strideWidth + threadIdx.x] = 0; 
}





static int cunn_BilinearSamplerBHWD_updateGradInput(lua_State *L)
{
  THCState *state = getCutorchState(L);
  THCudaTensor *inputImages = (THCudaTensor *)luaT_checkudata(L, 2, "torch.CudaTensor");
  THCudaTensor *grids = (THCudaTensor *)luaT_checkudata(L, 3, "torch.CudaTensor");
  THCudaTensor *gradInputImages = (THCudaTensor *)luaT_checkudata(L, 4, "torch.CudaTensor");
  THCudaTensor *gradGrids = (THCudaTensor *)luaT_checkudata(L, 5, "torch.CudaTensor");
  THCudaTensor *gradOutput = (THCudaTensor *)luaT_checkudata(L, 6, "torch.CudaTensor");

   dim3 blocks((gradOutput->size[2]+15)/16, gradOutput->size[1], gradOutput->size[0]);
   dim3 threads(32,16);

   backwardBilinearSampling <false> <<< blocks, threads, 0, THCState_getCurrentStream(state) >>> (
                                                      THCudaTensor_data(state, inputImages), 
                                                      THCudaTensor_stride(state, inputImages, 0),
                                                      THCudaTensor_stride(state, inputImages, 3),
                                                      THCudaTensor_stride(state, inputImages, 1),
                                                      THCudaTensor_stride(state, inputImages, 2),
                                                      THCudaTensor_data(state, gradInputImages), 
                                                      THCudaTensor_stride(state, gradInputImages, 0),
                                                      THCudaTensor_stride(state, gradInputImages, 3),
                                                      THCudaTensor_stride(state, gradInputImages, 1),
                                                      THCudaTensor_stride(state, gradInputImages, 2),
                                                      THCudaTensor_data(state, grids), 
                                                      THCudaTensor_stride(state, grids, 0),
                                                      THCudaTensor_stride(state, grids, 3),
                                                      THCudaTensor_stride(state, grids, 1),
                                                      THCudaTensor_stride(state, grids, 2),
                                                      THCudaTensor_data(state, gradGrids), 
                                                      THCudaTensor_stride(state, gradGrids, 0),
                                                      THCudaTensor_stride(state, gradGrids, 3),
                                                      THCudaTensor_stride(state, gradGrids, 1),
                                                      THCudaTensor_stride(state, gradGrids, 2),
                                                      THCudaTensor_data(state, gradOutput), 
                                                      THCudaTensor_stride(state, gradOutput, 0),
                                                      THCudaTensor_stride(state, gradOutput, 3),
                                                      THCudaTensor_stride(state, gradOutput, 1),
                                                      THCudaTensor_stride(state, gradOutput, 2),
                                                      THCudaTensor_size(state, inputImages, 3),
                                                      THCudaTensor_size(state, inputImages, 1), 
                                                      THCudaTensor_size(state, inputImages, 2),
                                                      THCudaTensor_size(state, gradOutput, 2));



  // check for errors
  cudaError_t err = cudaGetLastError();
  if (err != cudaSuccess) {
    printf("error in BilinearSampler.updateGradInput: %s\n", cudaGetErrorString(err));
    THError("aborting");
  }
  return 1;
}


static int cunn_BilinearSamplerBHWD_updateGradInputOnlyGrid(lua_State *L)
{
  THCState *state = getCutorchState(L);
  THCudaTensor *inputImages = (THCudaTensor *)luaT_checkudata(L, 2, "torch.CudaTensor");
  THCudaTensor *grids = (THCudaTensor *)luaT_checkudata(L, 3, "torch.CudaTensor");
  THCudaTensor *gradGrids = (THCudaTensor *)luaT_checkudata(L, 5, "torch.CudaTensor");
  THCudaTensor *gradOutput = (THCudaTensor *)luaT_checkudata(L, 6, "torch.CudaTensor");

   dim3 blocks((gradOutput->size[2]+15)/16, gradOutput->size[1], gradOutput->size[0]);
   dim3 threads(32,16);

   backwardBilinearSampling <true> <<< blocks, threads, 0, THCState_getCurrentStream(state) >>> (
                                                      THCudaTensor_data(state, inputImages), 
                                                      THCudaTensor_stride(state, inputImages, 0),
                                                      THCudaTensor_stride(state, inputImages, 3),
                                                      THCudaTensor_stride(state, inputImages, 1),
                                                      THCudaTensor_stride(state, inputImages, 2),
                                                      0, 
                                                      0,
                                                      0,
                                                      0,
                                                      0,
                                                      THCudaTensor_data(state, grids), 
                                                      THCudaTensor_stride(state, grids, 0),
                                                      THCudaTensor_stride(state, grids, 3),
                                                      THCudaTensor_stride(state, grids, 1),
                                                      THCudaTensor_stride(state, grids, 2),
                                                      THCudaTensor_data(state, gradGrids), 
                                                      THCudaTensor_stride(state, gradGrids, 0),
                                                      THCudaTensor_stride(state, gradGrids, 3),
                                                      THCudaTensor_stride(state, gradGrids, 1),
                                                      THCudaTensor_stride(state, gradGrids, 2),
                                                      THCudaTensor_data(state, gradOutput), 
                                                      THCudaTensor_stride(state, gradOutput, 0),
                                                      THCudaTensor_stride(state, gradOutput, 3),
                                                      THCudaTensor_stride(state, gradOutput, 1),
                                                      THCudaTensor_stride(state, gradOutput, 2),
                                                      THCudaTensor_size(state, inputImages, 3),
                                                      THCudaTensor_size(state, inputImages, 1), 
                                                      THCudaTensor_size(state, inputImages, 2),
                                                      THCudaTensor_size(state, gradOutput, 2));



  // check for errors
  cudaError_t err = cudaGetLastError();
  if (err != cudaSuccess) {
    printf("error in BilinearSampler.updateGradInput: %s\n", cudaGetErrorString(err));
    THError("aborting");
  }
  return 1;
}



static const struct luaL_Reg cunn_BilinearSamplerBHWD__ [] = {
  {"BilinearSamplerBHWD_updateOutput", cunn_BilinearSamplerBHWD_updateOutput},
  {"BilinearSamplerBHWD_updateGradInput", cunn_BilinearSamplerBHWD_updateGradInput},
  {"BilinearSamplerBHWD_updateGradInputOnlyGrid", cunn_BilinearSamplerBHWD_updateGradInputOnlyGrid},
  {NULL, NULL}
};

static void cunn_BilinearSamplerBHWD_init(lua_State *L)
{
  luaT_pushmetatable(L, "torch.CudaTensor");
  luaT_registeratname(L, cunn_BilinearSamplerBHWD__, "nn");
  lua_pop(L,1);
}
