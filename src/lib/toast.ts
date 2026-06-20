import { toast } from 'sonner';

export const showToast = {
  success: (message: string) => {
    toast.success(message, {
      duration: 3000,
      position: 'top-right',
    });
  },
  error: (message: string) => {
    toast.error(message, {
      duration: 4000,
      position: 'top-right',
    });
  },
  loading: (message: string) => {
    return toast.loading(message, {
      position: 'top-right',
    });
  },
  dismiss: (id: string | number) => {
    toast.dismiss(id);
  },
};

export const getErrorMessage = (error: any): string => {
  if (error?.response?.data?.message) {
    const msg = error.response.data.message;
    return Array.isArray(msg) ? msg.join(', ') : msg;
  }
  if (error?.message) {
    return error.message;
  }
  return 'An unexpected error occurred';
};
