# GRU Neural Network Based Equalizer on FPGA

This project implements a **Gated Recurrent Unit (GRU)** based **neural network equalizer** for BPSK communication systems, deployed on an **Intel DE10-Lite FPGA**.  
The GRU model was trained using **PyTorch**, and the trained weights were quantized and integrated into FPGA logic for real-time signal equalization.

---

## 🚀 Project Overview

| Parameter | Description |
|------------|--------------|
| **Modulation** | BPSK |
| **Model Inputs** | 3 input features, sequence length 3 |
| **GRU Architecture** | 3 neurons, single layer |
| **Hardware Platform** | Intel DE10-Lite FPGA |
| **Logic Utilization** | 24,670 Logic Blocks |
| **Inference Latency** | 86 µs per sequence |
| **Test Accuracy** | < 1% error across 8 test cases |

---

## ⚙️ Implementation Workflow

1. **Model Training (Python + PyTorch)**
   - Designed a lightweight GRU model for channel equalization.
   - Trained on noisy BPSK sequences generated in Python.
   - Exported trained weights for fixed-point FPGA implementation.

2. **Hardware Deployment**
   - Weights converted and integrated into HDL.
   - Implemented custom GRU cell using Verilog.
   - Deployed on **Intel DE10-Lite FPGA** using **Intel Quartus Prime**.
   - Measured real-time inference using onboard testbench.

3. **Testing**
   - Evaluated on 8 channel scenarios (AWGN + mild multipath).
   - Achieved <1% symbol error rate on all test cases.

---

## 📊 Results

| Test Case | Channel Type | Error (%) | Inference Time (µs) |
|------------|---------------|------------|---------------------|
| 1 | AWGN (low noise) | 0.2 | 86 |
| 2 | AWGN (moderate) | 0.5 | 86 |
| 3 | AWGN (high) | 0.8 | 86 |
| ... | ... | ... | ... |

*(Include actual table from your data if available)*

---

## 🧩 Tools and Technologies

- **PyTorch** – GRU model design and training  
- **NumPy, Matplotlib** – Data generation and visualization  
- **Intel Quartus Prime** – FPGA synthesis and deployment  
- **Verilog** – Custom GRU cell and equalizer logic implementation  
- **Python → HDL workflow** – Quantized weight integration

---

## 🧠 Key Highlights

- Designed a compact GRU NN optimized for FPGA logic constraints.  
- Achieved real-time equalization at microsecond-scale latency.  
- Demonstrated generalization across multiple BPSK test scenarios.  
- Balanced accuracy and resource utilization effectively.

---

## 📸 Hardware Results

*(Add your photos here, e.g. screenshots or oscilloscope captures)*  
Example:
