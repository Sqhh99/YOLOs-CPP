/**
 * @file camera_inference.cpp
 * @brief Real-time object detection using YOLO models (v5, v7, v8, v9, v10, v11, v12) with camera input.
 * 
 * This file serves as the main entry point for a real-time object detection 
 * application that utilizes YOLO (You Only Look Once) models, specifically 
 * versions 5, 7, 8, 9, 10, 11 and 12. The application captures video frames from a 
 * specified camera device, processes those frames to detect objects, and 
 * displays the results with bounding boxes around detected objects.
 *
 * The program operates in a multi-threaded environment, featuring the following 
 * threads:
 * 1. **Producer Thread**: Responsible for capturing frames from the video source 
 *    and enqueuing them into a thread-safe bounded queue for subsequent processing.
 * 2. **Consumer Thread**: Dequeues frames from the producer's queue, executes 
 *    object detection using the specified YOLO model, and enqueues the processed 
 *    frames along with detection results into another thread-safe bounded queue.
 * 3. **Display Thread**: Dequeues processed frames from the consumer's queue, 
 *    draws bounding boxes around detected objects, and displays the frames to the 
 *    user.
 *
 * Configuration parameters can be adjusted to suit specific requirements:
 * - `isGPU`: Set to true to enable GPU processing for improved performance; 
 *   set to false for CPU processing.
 * - `labelsPath`: Path to the class labels file (e.g., COCO dataset).
 * - `modelPath`: Path to the desired YOLO model file (e.g., ONNX format).
 * - `videoSource`: Path to the video capture device (e.g., camera).
 *
 * The application employs a double buffering technique by maintaining two bounded 
 * queues to efficiently manage the flow of frames between the producer and 
 * consumer threads. This setup helps prevent processing delays due to slow frame 
 * capture or detection times.
 *
 * Debugging messages can be enabled by defining the `DEBUG_MODE` macro, allowing 
 * developers to trace the execution flow and internal state of the application 
 * during runtime.
 *
 * Usage Instructions:
 * 1. Compile the application with the necessary OpenCV and YOLO dependencies.
 * 2. Run the executable to initiate the object detection process.
 * 3. Press 'q' to quit the application at any time.
 *
 * @note Ensure that the required model files and labels are present in the 
 * specified paths before running the application.
 *
 * Author: YOLOs-CPP Team, https://github.com/Geekgineer/YOLOs-CPP
 * Date: 29.09.2024
 */


#include <iostream>
#include <vector>
#include <thread>
#include <atomic>
#include <algorithm>
#include <cctype>
#include <exception>
#include <string>

#include <opencv2/highgui/highgui.hpp>
// #ifndef DEBUG_MODE
// #define DEBUG_MODE
// #endif
// #ifndef TIMING_MODE
// #define TIMING_MODE
// #endif
#include "yolos/tasks/detection.hpp"

using namespace yolos::det;


// Include the bounded queue
#include "tools/BoundedThreadSafeQueue.hpp"

namespace {

void printUsage(const char* programName)
{
    std::cout << "Usage: " << programName
              << " [model_path] [camera_index_or_video_path] [labels_path] [use_gpu]\n"
              << "  use_gpu: 1/gpu/cuda/true or 0/cpu/false (default: 1)" << std::endl;
}

std::string toLower(std::string value)
{
    std::transform(value.begin(), value.end(), value.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return value;
}

bool parseGpuFlag(const std::string& value, bool& useGPU)
{
    const std::string normalized = toLower(value);
    if (normalized == "1" || normalized == "true" || normalized == "gpu" || normalized == "cuda") {
        useGPU = true;
        return true;
    }
    if (normalized == "0" || normalized == "false" || normalized == "cpu") {
        useGPU = false;
        return true;
    }
    return false;
}

bool isCameraIndex(const std::string& value)
{
    return !value.empty() &&
           std::all_of(value.begin(), value.end(),
                       [](unsigned char c) { return std::isdigit(c) != 0; });
}

bool openVideoCapture(cv::VideoCapture& cap, const std::string& source)
{
    if (isCameraIndex(source)) {
        const int cameraIndex = std::stoi(source);
#ifdef _WIN32
        return cap.open(cameraIndex, cv::CAP_ANY);
#elif defined(__linux__)
        return cap.open(cameraIndex, cv::CAP_V4L2);
#else
        return cap.open(cameraIndex, cv::CAP_ANY);
#endif
    }

#ifdef _WIN32
    return cap.open(source, cv::CAP_ANY);
#else
    return cap.open(source);
#endif
}

} // namespace

int main(int argc, char* argv[])
{
    // Configuration parameters
    bool isGPU = true;
    std::string labelsPath = "../models/coco.names";
    std::string modelPath = "../models/yolo11n.onnx";

    std::string videoSource = "0"; // camera index or video file path
    if (argc > 1){
        modelPath = argv[1];
    }
    if (argc > 2){
        videoSource = argv[2];
    }
    if (argc > 3){
        labelsPath = argv[3];
    }
    if (argc > 4 && !parseGpuFlag(argv[4], isGPU)) {
        std::cerr << "Invalid use_gpu value: " << argv[4] << std::endl;
        printUsage(argv[0]);
        return -1;
    }

    try {
        YOLODetector detector(modelPath, labelsPath, isGPU);


        // Open video capture
        cv::VideoCapture cap;
        if (!openVideoCapture(cap, videoSource))
        {
            std::cerr << "Error: Could not open the camera or video source: " << videoSource << "\n";
            return -1;
        }

        std::cout << "[INFO] Inference device: " << (isGPU ? "GPU (CUDA)" : "CPU") << std::endl;
        std::cout << "[INFO] Model loaded: " << modelPath << std::endl;
        std::cout << "[INFO] Video source: " << videoSource << std::endl;

        // Set camera properties
        cap.set(cv::CAP_PROP_FRAME_WIDTH, 1280);
        cap.set(cv::CAP_PROP_FRAME_HEIGHT, 720);
        cap.set(cv::CAP_PROP_FPS, 30);

        // Initialize queues with bounded capacity
        const size_t max_queue_size = 2; // Double buffering
        BoundedThreadSafeQueue<cv::Mat> frameQueue(max_queue_size);
        BoundedThreadSafeQueue<std::pair<cv::Mat, std::vector<Detection>>> processedQueue(max_queue_size);
        std::atomic<bool> stopFlag(false);
        std::atomic<bool> inferenceError(false);

        // Producer thread: Capture frames
        std::thread producer([&]() {
            cv::Mat frame;
            while (!stopFlag.load() && cap.read(frame))
            {
                if (!frameQueue.enqueue(frame))
                    break; // Queue is finished
            }
            frameQueue.set_finished();
        });

        // Consumer thread: Process frames
        std::thread consumer([&]() {
            try {
                cv::Mat frame;
                while (!stopFlag.load() && frameQueue.dequeue(frame))
                {
                    // Perform detection
                    std::vector<Detection> detections = detector.detect(frame);

                    // Enqueue processed frame
                    if (!processedQueue.enqueue(std::make_pair(frame, detections)))
                        break;
                }
            } catch (const Ort::Exception& e) {
                std::cerr << "ONNX Runtime error: " << e.what() << std::endl;
                inferenceError.store(true);
                stopFlag.store(true);
                frameQueue.set_finished();
            } catch (const std::exception& e) {
                std::cerr << "Error during camera inference: " << e.what() << std::endl;
                inferenceError.store(true);
                stopFlag.store(true);
                frameQueue.set_finished();
            } catch (...) {
                std::cerr << "Unknown error during camera inference." << std::endl;
                inferenceError.store(true);
                stopFlag.store(true);
                frameQueue.set_finished();
            }
            processedQueue.set_finished();
        });

        std::pair<cv::Mat, std::vector<Detection>> item;

    #ifdef __APPLE__
        // For macOS, ensure UI runs on the main thread
        while (!stopFlag.load() && processedQueue.dequeue(item))
        {
            cv::Mat displayFrame = item.first;
            detector.drawDetectionsWithMask(displayFrame, item.second);

            cv::imshow("Detections", displayFrame);
            if (cv::waitKey(1) == 'q')
            {
                stopFlag.store(true);
                frameQueue.set_finished();
                processedQueue.set_finished();
                break;
            }
        }
    #else
        // Display thread: Show processed frames
        std::thread displayThread([&]() {
            while (!stopFlag.load() && processedQueue.dequeue(item))
            {
                cv::Mat displayFrame = item.first;
                // detector.drawDetections(displayFrame, item.second);
                detector.drawDetectionsWithMask(displayFrame, item.second);

                // Display the frame
                cv::imshow("Detections", displayFrame);
                // Use a small delay and check for 'q' key press to quit
                if (cv::waitKey(1) == 'q') {
                    stopFlag.store(true);
                    frameQueue.set_finished();
                    processedQueue.set_finished();
                    break;
                }
            }
        });
        displayThread.join();
    #endif

        // Join all threads
        producer.join();
        consumer.join();

        // Release resources
        cap.release();
        cv::destroyAllWindows();

        return inferenceError.load() ? -1 : 0;
    } catch (const Ort::Exception& e) {
        std::cerr << "ONNX Runtime error: " << e.what() << std::endl;
        if (isGPU) {
            std::cerr << "GPU inference was requested. Verify CUDA/cuDNN runtime compatibility "
                      << "or retry with use_gpu=0 for CPU inference." << std::endl;
        }
        return -1;
    } catch (const std::exception& e) {
        std::cerr << "Error: " << e.what() << std::endl;
        return -1;
    } catch (...) {
        std::cerr << "Unknown error during camera inference." << std::endl;
        return -1;
    }
}
