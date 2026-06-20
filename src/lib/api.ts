import axios, { AxiosError, AxiosInstance } from 'axios';

const api: AxiosInstance = axios.create({
  baseURL: process.env.NEXT_PUBLIC_API_URL || 'http://localhost:3001',
  headers: { 
    'Content-Type': 'application/json',
  },
  timeout: 30000,
});

// Request interceptor - add JWT token
api.interceptors.request.use((config) => {
  if (typeof window !== 'undefined') {
    const token = localStorage.getItem('access_token');
    if (token) {
      config.headers.Authorization = `Bearer ${token}`;
    }
  }
  return config;
});

// Response interceptor - handle errors and token expiry
api.interceptors.response.use(
  (response) => response,
  (error: AxiosError) => {
    if (error.response?.status === 401) {
      // Token expired or invalid
      if (typeof window !== 'undefined') {
        localStorage.removeItem('access_token');
        localStorage.removeItem('refresh_token');
        localStorage.removeItem('user');
        window.location.href = '/login';
      }
    }
    return Promise.reject(error);
  }
);

export default api;

// Helper functions for common API operations
export const apiClient = {
  get: (url: string, config = {}) => api.get(url, config),
  post: (url: string, data?: any, config = {}) => api.post(url, data, config),
  put: (url: string, data?: any, config = {}) => api.put(url, data, config),
  patch: (url: string, data?: any, config = {}) => api.patch(url, data, config),
  delete: (url: string, config = {}) => api.delete(url, config),
};

export type ApiError = AxiosError;
