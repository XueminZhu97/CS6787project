
#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include <stdio.h>
#include <iostream>  
#include <pthread.h>
#include <fstream>
#include <sstream>    
#include <opencv2/core/core.hpp>
#include <opencv2/highgui/highgui.hpp>
#include <opencv2/opencv.hpp>
#include <cuda.h>
#include <cudnn.h>
#include <ctime>
#include <wchar.h>




#define NUM_OF_CONV_LAYERS 12
#define NUM_OF_PCA_DIMS 15

clock_t start_t, end_t;
using namespace std;
using namespace cv;
const char *inputpath, *outputpath, *modelpath = "model";
int scale_factor = 2;
int noise_level = 3;
vector<cv::String> imageSet;


#define checkCUDNN(expression)                                  \
  {                                                             \
  cudnnStatus_t status = (expression);                        \
if (status != CUDNN_STATUS_SUCCESS) { \
	std::cerr << "Error on line " << __LINE__ << ": "       \
	<< cudnnGetErrorString(status) << std::endl;            \
	std::exit(EXIT_FAILURE);                                \
}                                                           \
  }



__global__ void conv_bias_add(float *vector, const float* bias, const int sizeOfmaps, const int numOfmaps)
{
	unsigned int ix = threadIdx.x + blockIdx.x * blockDim.x;
	unsigned int iy = threadIdx.y + blockIdx.y * blockDim.y;
	unsigned int idx = iy * sizeOfmaps + ix;
	vector[idx] += bias[iy];
}





static char* optarg = NULL;
static int optind = 1;
static char getopt(int argc, char* const argv[], const wchar_t* optstring)
{
	if (optind >= argc)
		return ' ';
	char opt = argv[optind][1];
	const wchar_t* p = wcschr(optstring, (wchar_t)opt);
	if (p == NULL)
		return L'?';
	optarg = NULL;

	if (p[1] == L':')
	{
		optind++;
		if (optind >= argc)
			return L'?';

		optarg = (char*)(argv[optind]);
	}

	optind++;
	return opt;
}


static void print_usage()
{
	fprintf(stderr, "Usage: sr-cuda -i infile -o outfile [options]...\n\n");
	fprintf(stderr, "  -h                   show this help\n");
	fprintf(stderr, "  -i input-path        input image path (jpg/png) or directory\n");
	fprintf(stderr, "  -o output-path       output image path (jpg/png) or directory\n");
	fprintf(stderr, "  -n noise-level       denoise level (-1/0/1/2/3/4/5/6/7/8/9/10, default=3)\n");
	fprintf(stderr, "  -s scale             upscale ratio (2/3/4, default=2)\n");
	fprintf(stderr, "  -m model-path        model path (default=model)\n");
}



struct pixelShuffle_args
{
	int rows;
	int cols;
	Mat* image_H;
	int item;
	float* outputBuffer;
};
void* pixelShuffle (void* args) 
{
	pixelShuffle_args data;
	data=*(pixelShuffle_args*)args;
	int rows=data.rows;
	int cols=data.cols;
	Mat* image_H=data.image_H;
	int item=data.item;
	float* outputBuffer=data.outputBuffer;
	int image_size = rows*cols;
	int sf_pow = scale_factor * scale_factor;
	for (int row = 0; row < rows; row++)
	{
		for (int col = 0; col < cols; col++)
		{
			int ptr = row * cols + col;
			for (int i = 0; i < 3; i++)
			{
				for (int j = 0; j < scale_factor; j++)
				{
					for (int k = 0; k < scale_factor; k++)
					{
						float data = outputBuffer[(sf_pow * i + scale_factor * j + k)* image_size + ptr];
						(*image_H).at<Vec3b>(scale_factor * row + j, scale_factor * col + k)[2-i] = (uchar)(data < 1.f ? data * 255.f : 255);
					}
				}
			}
		}
	}
	if (imageSet.size() == 1)
	{
		imwrite(string(outputpath), image_H);
	}
	else
	{
		for (int i = imageSet[item].size() - 1; i >= 0; i--)
		{
			if (imageSet[item][i] == '/')
			{
				imageSet[item] = imageSet[item].substr(i, imageSet[item].size() - i);
				break;
			}
		}
		imwrite(outputpath + imageSet[item], image_H);
	}
}

int main(int argc, char** argv)
{
	if (argc == 1)
	{
		print_usage();
		return -1;
	}
	char opt;
	while ((opt = getopt(argc, argv, L"i:o:n:s:t:m:g:j:f:vxh")) != ' ')
	{
		switch (opt)
		{
		case 'i':
			inputpath = optarg;
			break;
		case 'o':
			outputpath = optarg;
			break;
		case 'n':
			noise_level = atoi(optarg);
			break;
		case 's':
			scale_factor = atoi(optarg);
			break;
		case 'm':
			modelpath = optarg;
			break;
		case 'h':
		default:
			print_usage();
			return -1;
		}
	}
	int input_channels;
	string modelpath_str;
	if (noise_level == -1)
	{
		input_channels = 18;
		modelpath_str = string(modelpath) + string("/srnf_x") + to_string(scale_factor) + string(".acc");
	}
	else if (0 <= noise_level && noise_level <= 10)
	{
		input_channels = 19;
		modelpath_str = string(modelpath) + string("/sr_x") + to_string(scale_factor) + string(".acc");
	}
	else
	{
		return -1;
	}
	modelpath = modelpath_str.c_str();
	std::ifstream model(modelpath, std::ios::in | ios::binary);
	model.read((char*)&scale_factor, 4);
	float pca_kernel[NUM_OF_PCA_DIMS];
	float* conv_kernel_weights[NUM_OF_CONV_LAYERS];
	float* conv_kernel_bias[NUM_OF_CONV_LAYERS];
	conv_kernel_weights[0] = new float[9 * input_channels * 128];
	conv_kernel_bias[0] = new float[128];
	for (int i = 1; i < NUM_OF_CONV_LAYERS - 1; i++)
	{
		conv_kernel_weights[i] = new float[9 * 128 * 128];
		conv_kernel_bias[i] = new float[128];
	}
	conv_kernel_weights[11] = new float[9 * 128 * 3 * scale_factor*scale_factor];
	conv_kernel_bias[11] = new float[3 * scale_factor*scale_factor];

	for (int i = 0; i < NUM_OF_PCA_DIMS; i++)
	{
		model.read((char*)&pca_kernel[i], 4);
	}
	for (int j = 0; j < 9 * input_channels * 128; j++)
	{
		model.read((char*)&conv_kernel_weights[0][j], 4);
	}
	for (int j = 0; j < 128; j++)
	{
		model.read((char*)&conv_kernel_bias[0][j], 4);
	}
	for (int i = 1; i < NUM_OF_CONV_LAYERS - 1; i++)
	{
		for (int j = 0; j < 9 * 128 * 128; j++)
		{
			model.read((char*)&conv_kernel_weights[i][j], 4);
		}
		for (int j = 0; j < 128; j++)
		{
			model.read((char*)&conv_kernel_bias[i][j], 4);
		}
	}

	for (int j = 0; j < 9 * 128 * 3 * scale_factor*scale_factor; j++)
	{
		model.read((char*)&conv_kernel_weights[11][j], 4);
	}
	for (int j = 0; j < 3 * scale_factor*scale_factor; j++)
	{
		model.read((char*)&conv_kernel_bias[11][j], 4);
	}
	model.close();
	cudnnHandle_t handle;
	cudnnCreate(&handle);
	Mat image;
		glob(inputpath, imageSet, false);
		if (imageSet.empty())
			return -1;
		else
			image = imread(imageSet[0]);

	Mat image_H(image.rows*scale_factor, image.cols*scale_factor, CV_8UC3);
	int image_size = image.rows*image.cols;
	int buffer_size = image_size * 3 * sizeof(float);
	float* inputBuffer = (float *)malloc(input_channels * image_size * sizeof(float));
	float* outputBuffer = (float *)malloc(buffer_size * scale_factor * scale_factor);


	
	cudnnTensorDescriptor_t input_descriptor_first;
	checkCUDNN(cudnnCreateTensorDescriptor(&input_descriptor_first));
	checkCUDNN(cudnnSetTensor4dDescriptor(input_descriptor_first,
		/*format=*/CUDNN_TENSOR_NCHW,
		/*dataType=*/CUDNN_DATA_FLOAT,
		/*batch_size=*/1,
		/*channels=*/input_channels,
		/*image_height=*/image.rows,
		/*image_width=*/image.cols));

	
	cudnnFilterDescriptor_t kernel_descriptor_first;
	checkCUDNN(cudnnCreateFilterDescriptor(&kernel_descriptor_first));
	checkCUDNN(cudnnSetFilter4dDescriptor(kernel_descriptor_first,
		/*dataType=*/CUDNN_DATA_FLOAT,
		/*format=*/CUDNN_TENSOR_NCHW,	
		/*out_channels=*/128,
		/*in_channels=*/input_channels,
		/*kernel_height=*/3,
		/*kernel_width=*/3));

	
	cudnnConvolutionDescriptor_t convolution_descriptor_first;
	checkCUDNN(cudnnCreateConvolutionDescriptor(&convolution_descriptor_first));
	checkCUDNN(cudnnSetConvolution2dDescriptor(convolution_descriptor_first,
		/*pad_height=*/1,
		/*pad_width=*/1,
		/*vertical_stride=*/1,
		/*horizontal_stride=*/1,
		/*dilation_height=*/1,
		/*dilation_width=*/1,
		/*mode=*/CUDNN_CROSS_CORRELATION, 
		/*computeType=*/CUDNN_DATA_FLOAT));

	
	cudnnTensorDescriptor_t output_descriptor_first;
	checkCUDNN(cudnnCreateTensorDescriptor(&output_descriptor_first));
	checkCUDNN(cudnnSetTensor4dDescriptor(output_descriptor_first,
		/*format=*/CUDNN_TENSOR_NCHW,
		/*dataType=*/CUDNN_DATA_FLOAT,
		/*batch_size=*/1,
		/*channels=*/128,
		/*image_height=*/image.rows,
		/*image_width=*/image.cols));

	
  
  
  
	cudnnConvolutionFwdAlgo_t convolution_algorithm_first;
	checkCUDNN(
		cudnnGetConvolutionForwardAlgorithm(handle,
			input_descriptor_first,
			kernel_descriptor_first,
			convolution_descriptor_first,
			output_descriptor_first,
			CUDNN_CONVOLUTION_FWD_PREFER_FASTEST, 
			/*memoryLimitInBytes=*/0,
			&convolution_algorithm_first));



	cudnnTensorDescriptor_t input_descriptor_mid;
	checkCUDNN(cudnnCreateTensorDescriptor(&input_descriptor_mid));
	checkCUDNN(cudnnSetTensor4dDescriptor(input_descriptor_mid,
		/*format=*/CUDNN_TENSOR_NCHW,	
		/*dataType=*/CUDNN_DATA_FLOAT,
		/*batch_size=*/1,
		/*channels=*/128,
		/*image_height=*/image.rows,
		/*image_width=*/image.cols

	
	cudnnFilterDescriptor_t kernel_descriptor_mid;
	checkCUDNN(cudnnCreateFilterDescriptor(&kernel_descriptor_mid));
	checkCUDNN(cudnnSetFilter4dDescriptor(kernel_descriptor_mid,
		/*dataType=*/CUDNN_DATA_FLOAT,
		/*format=*/CUDNN_TENSOR_NCHW,	
		/*out_channels=*/128,
		/*in_channels=*/128,
		/*kernel_height=*/3,
		/*kernel_width=*/3));

	
	cudnnConvolutionDescriptor_t convolution_descriptor_mid;
	checkCUDNN(cudnnCreateConvolutionDescriptor(&convolution_descriptor_mid));
	checkCUDNN(cudnnSetConvolution2dDescriptor(convolution_descriptor_mid,
		/*pad_height=*/1,
		/*pad_width=*/1,
		/*vertical_stride=*/1,
		/*horizontal_stride=*/1,
		/*dilation_height=*/1,
		/*dilation_width=*/1,
		/*mode=*/CUDNN_CROSS_CORRELATION, 
		/*computeType=*/CUDNN_DATA_FLOAT));


	
	cudnnTensorDescriptor_t output_descriptor_mid;
	checkCUDNN(cudnnCreateTensorDescriptor(&output_descriptor_mid));
	checkCUDNN(cudnnSetTensor4dDescriptor(output_descriptor_mid,
		/*format=*/CUDNN_TENSOR_NCHW,
		/*dataType=*/CUDNN_DATA_FLOAT,
		/*batch_size=*/1,
		/*channels=*/128,
		/*image_height=*/image.rows,
		/*image_width=*/image.cols));

	
  
  
  
	cudnnConvolutionFwdAlgo_t convolution_algorithm_mid;
	checkCUDNN(
		cudnnGetConvolutionForwardAlgorithm(handle,
			input_descriptor_mid,
			kernel_descriptor_mid,
			convolution_descriptor_mid,
			output_descriptor_mid,
			CUDNN_CONVOLUTION_FWD_PREFER_FASTEST, 
			/*memoryLimitInBytes=*/0,
			&convolution_algorithm_mid));



	cudnnTensorDescriptor_t input_descriptor_last;
	checkCUDNN(cudnnCreateTensorDescriptor(&input_descriptor_last));
	checkCUDNN(cudnnSetTensor4dDescriptor(input_descriptor_last,
		/*format=*/CUDNN_TENSOR_NCHW,	
		/*dataType=*/CUDNN_DATA_FLOAT,
		/*batch_size=*/1,
		/*channels=*/128,
		/*image_height=*/image.rows,
		/*image_width=*/image.cols));

	
	cudnnFilterDescriptor_t kernel_descriptor_last;
	checkCUDNN(cudnnCreateFilterDescriptor(&kernel_descriptor_last));
	checkCUDNN(cudnnSetFilter4dDescriptor(kernel_descriptor_last,
		/*dataType=*/CUDNN_DATA_FLOAT,
		/*format=*/CUDNN_TENSOR_NCHW,	
		/*out_channels=*/3 * scale_factor*scale_factor,
		/*in_channels=*/128,
		/*kernel_height=*/3,
		/*kernel_width=*/3));

	
	cudnnConvolutionDescriptor_t convolution_descriptor_last;
	checkCUDNN(cudnnCreateConvolutionDescriptor(&convolution_descriptor_last));
	checkCUDNN(cudnnSetConvolution2dDescriptor(convolution_descriptor_last,
		/*pad_height=*/1,
		/*pad_width=*/1,
		/*vertical_stride=*/1,
		/*horizontal_stride=*/1,
		/*dilation_height=*/1,
		/*dilation_width=*/1,
		/*mode=*/CUDNN_CROSS_CORRELATION, 
		/*computeType=*/CUDNN_DATA_FLOAT));

	
	cudnnTensorDescriptor_t output_descriptor_last;
	checkCUDNN(cudnnCreateTensorDescriptor(&output_descriptor_last));
	checkCUDNN(cudnnSetTensor4dDescriptor(output_descriptor_last,
		/*format=*/CUDNN_TENSOR_NCHW,
		/*dataType=*/CUDNN_DATA_FLOAT,
		/*batch_size=*/1,
		/*channels=*/3 * scale_factor*scale_factor,
		/*image_height=*/image.rows,
		/*image_width=*/image.cols));

	
  
  
  
	cudnnConvolutionFwdAlgo_t convolution_algorithm_last;
	checkCUDNN(
		cudnnGetConvolutionForwardAlgorithm(handle,
			input_descriptor_last,
			kernel_descriptor_last,
			convolution_descriptor_last,
			output_descriptor_last,
			CUDNN_CONVOLUTION_FWD_PREFER_FASTEST, 
			/*memoryLimitInBytes=*/0,
			&convolution_algorithm_last));

	
	size_t workspace_bytes{ 0 };
	checkCUDNN(cudnnGetConvolutionForwardWorkspaceSize(handle,
		input_descriptor_mid,
		kernel_descriptor_mid,
		convolution_descriptor_mid,
		output_descriptor_mid,
		convolution_algorithm_mid,
		&workspace_bytes));

	cudnnActivationDescriptor_t activation_descriptor;
	checkCUDNN(cudnnCreateActivationDescriptor(&activation_descriptor));
	checkCUDNN(cudnnSetActivationDescriptor(activation_descriptor,
		CUDNN_ACTIVATION_RELU,
		CUDNN_PROPAGATE_NAN,
		/*relu_coef=*/0));


	
		
	void* d_workspace{ nullptr };
	cudaMalloc(&d_workspace, workspace_bytes);


	
	int size_of_featuremap = 128 * image_size * sizeof(float);

	float* d_featuremap_1{ nullptr };
	cudaMalloc(&d_featuremap_1, size_of_featuremap);

	float* d_featuremap_2{ nullptr };
	cudaMalloc(&d_featuremap_2, size_of_featuremap);
	
	/*
	float h_kernel[128][18][3][3]; 
	for (int kernel = 0; kernel < 128; ++kernel) {
		for (int channel = 0; channel < 18; ++channel) {
			for (int row = 0; row < 3; ++row) {
				for (int column = 0; column < 3; ++column) {
					h_kernel[kernel][channel][row][column] = conv_kernel_weights[0][kernel*18*3*3+channel*3*3+row*3+ column];
				}
			}
		}
	}
	*/
	float* d_kernel[NUM_OF_CONV_LAYERS];
	cudaMalloc(&d_kernel[0], input_channels * 128 * 3 * 3 * sizeof(float));
	cudaMemcpy(d_kernel[0], conv_kernel_weights[0], input_channels * 128 * 3 * 3 * sizeof(float), cudaMemcpyHostToDevice);
	for (int i = 1; i < NUM_OF_CONV_LAYERS - 1; i++)
	{
		cudaMalloc(&d_kernel[i], 128 * 128 * 3 * 3 * sizeof(float));
		cudaMemcpy(d_kernel[i], conv_kernel_weights[i], 128 * 128 * 3 * 3 * sizeof(float), cudaMemcpyHostToDevice);
	}
	cudaMalloc(&d_kernel[NUM_OF_CONV_LAYERS - 1], 128 * 3 * scale_factor*scale_factor * 3 * 3 * sizeof(float));
	cudaMemcpy(d_kernel[NUM_OF_CONV_LAYERS - 1], conv_kernel_weights[NUM_OF_CONV_LAYERS - 1], 128 * 3 * scale_factor*scale_factor * 3 * 3 * sizeof(float), cudaMemcpyHostToDevice);

	float* d_bias[NUM_OF_CONV_LAYERS];
	for (int i = 0; i < NUM_OF_CONV_LAYERS - 1; i++)
	{
		cudaMalloc(&d_bias[i], 128 * sizeof(float));
		cudaMemcpy(d_bias[i], conv_kernel_bias[i], 128 * sizeof(float), cudaMemcpyHostToDevice);
	}
	cudaMalloc(&d_bias[NUM_OF_CONV_LAYERS - 1], 3 * scale_factor*scale_factor * sizeof(float));
	cudaMemcpy(d_bias[NUM_OF_CONV_LAYERS - 1], conv_kernel_bias[NUM_OF_CONV_LAYERS - 1], 3 * scale_factor*scale_factor * sizeof(float), cudaMemcpyHostToDevice);

	for (int i = 0; i < NUM_OF_PCA_DIMS; i++)
	{
		for (int row = 0; row < image.rows; row++)
		{
			for (int col = 0; col < image.cols; col++)
			{
				inputBuffer[(3 + i)* image_size + row * image.cols + col] = pca_kernel[i];
			}
		}
	}

	if (noise_level != -1)
	{

		for (int row = 0; row < image.rows; row++)
		{
			for (int col = 0; col < image.cols; col++)
			{
				inputBuffer[(input_channels - 1) * image_size + row * image.cols + col] = noise_level / 255.f;
			}
		}
	}

	for (int i = 0; i < NUM_OF_CONV_LAYERS; i++)
	{
		delete conv_kernel_weights[i];
		delete conv_kernel_bias[i];
	}
	pthread_t pixelShuffle_thread;
	pixelShuffle_args args;
	for (int item = 0; item < imageSet.size(); item++)
	{
		start_t = clock();
		image = imread(imageSet[item]);
		for (int row = 0; row < image.rows; row++)
		{
			for (int col = 0; col < image.cols; col++)
			{
				
				inputBuffer[row*image.cols + col] = image.at<Vec3b>(row, col)[2] / 255.f;
				inputBuffer[image_size + row * image.cols + col] = image.at<Vec3b>(row, col)[1] / 255.f;
				inputBuffer[2 * image_size + row * image.cols + col] = image.at<Vec3b>(row, col)[0] / 255.f;
			}
		}

		cudaMemcpy(d_featuremap_1, inputBuffer, input_channels * image_size * sizeof(float), cudaMemcpyHostToDevice);

		
		const float alpha = 1.0f, beta = 0.0f;
		
		checkCUDNN(cudnnConvolutionForward(handle,
			&alpha,
			input_descriptor_first,
			d_featuremap_1,
			kernel_descriptor_first,
			d_kernel[0],
			convolution_descriptor_first,
			convolution_algorithm_first,
			d_workspace, 
			workspace_bytes,
			&beta,
			output_descriptor_first,
			d_featuremap_2));

		int nx = image.rows*image.cols;
		int ny = 128;
		int dimx = 64;
		int dimy = 2;
		dim3 block(dimx, dimy);
		dim3 grid((nx + block.x - 1) / block.x, (ny + block.y - 1) / block.y);
		conv_bias_add << <grid, block >> > (d_featuremap_2, d_bias[0], nx, ny);



		
		checkCUDNN(cudnnActivationForward(handle,
			activation_descriptor,
			&alpha,
			output_descriptor_first,
			d_featuremap_2,
			&beta,
			output_descriptor_first,
			d_featuremap_2));
		

		for (int i = 1; i < NUM_OF_CONV_LAYERS - 1; i++)
		{
			if (i % 2 == 0)
			{
				const float alpha = 1.0f, beta = 0.0f;
				
				checkCUDNN(cudnnConvolutionForward(handle,
					&alpha,
					input_descriptor_mid,
					d_featuremap_1,
					kernel_descriptor_mid,
					d_kernel[i],
					convolution_descriptor_mid,
					convolution_algorithm_mid,
					d_workspace, 
					workspace_bytes,
					&beta,
					output_descriptor_mid,
					d_featuremap_2));

				conv_bias_add << <grid, block >> > (d_featuremap_2, d_bias[i], nx, ny);


				
				checkCUDNN(cudnnActivationForward(handle,
					activation_descriptor,
					&alpha,
					output_descriptor_mid,
					d_featuremap_2,
					&beta,
					output_descriptor_mid,
					d_featuremap_2));
			}
			else
			{
				const float alpha = 1.0f, beta = 0.0f;
				
				checkCUDNN(cudnnConvolutionForward(handle,
					&alpha,
					input_descriptor_mid,
					d_featuremap_2,
					kernel_descriptor_mid,
					d_kernel[i],
					convolution_descriptor_mid,
					convolution_algorithm_mid,
					d_workspace, 
					workspace_bytes,
					&beta,
					output_descriptor_mid,
					d_featuremap_1));

				conv_bias_add << <grid, block >> > (d_featuremap_1, d_bias[i], nx, ny);


				
				checkCUDNN(cudnnActivationForward(handle,
					activation_descriptor,
					&alpha,
					output_descriptor_mid,
					d_featuremap_1,
					&beta,
					output_descriptor_mid,
					d_featuremap_1));
			}
			
		}

		
		checkCUDNN(cudnnConvolutionForward(handle,
			&alpha,
			input_descriptor_last,
			d_featuremap_2,
			kernel_descriptor_last,
			d_kernel[NUM_OF_CONV_LAYERS - 1],
			convolution_descriptor_last,
			convolution_algorithm_last,
			d_workspace, 
			workspace_bytes,
			&beta,
			output_descriptor_last,
			d_featuremap_1));

		conv_bias_add << <grid, block >> > (d_featuremap_1, d_bias[NUM_OF_CONV_LAYERS - 1], nx, ny);

		
		checkCUDNN(cudnnActivationForward(handle,
			activation_descriptor,
			&alpha,
			output_descriptor_last,
			d_featuremap_1,
			&beta,
			output_descriptor_last,
			d_featuremap_1));
			if(item!=0)
				pthread_join(pixelShuffle_thread,NULL);
		cudaMemcpy(outputBuffer, d_featuremap_1, buffer_size * scale_factor * scale_factor, cudaMemcpyDeviceToHost);
		args.rows=image.rows;
		args.cols=image.cols;
		args.image_H=&image_H;
		args.item=item;
		args.outputBuffer=outputBuffer;
		pthread_create(&pixelShuffle_thread, NULL, pixelShuffle, (void *)&args);
		end_t = clock();
		cout << "time: " << (double)(end_t - start_t) / CLOCKS_PER_SEC * 1000 << " ms" << endl;
	}
	pthread_join(pixelShuffle_thread,NULL);
	
	
	
	
	
		
		
		
		
		
	return 0;
}
